#import "image_utils.h"
#import "vcam_shared.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <AVFoundation/AVFoundation.h>

// Hook BWNodeOutput and every concrete subclass that overrides
// emitSampleBuffer:. Some camera graph nodes dispatch through subclass IMPs,
// which a hook on BWNodeOutput alone does not intercept.
static void *sCMCaptureHandle = NULL;
static NSMutableDictionary<NSString *, NSValue *> *sOriginalIMPs;
static NSMutableSet<NSString *> *sHookedClasses;
static BOOL sVCamHookInstalled = NO;
static NSUInteger sVCamHookAttempts = 0;
static uint64_t sVCamHookFrameCount = 0;
static __thread int sVCamHookRecursionDepth = 0;

static IMP VCamOriginalIMPForObject(id object) {
    Class cls = object_getClass(object);
    @synchronized (sOriginalIMPs) {
        for (Class current = cls; current; current = class_getSuperclass(current)) {
            NSValue *value = sOriginalIMPs[NSStringFromClass(current)];
            if (value) return (IMP)value.pointerValue;
        }
    }
    return NULL;
}

static void VCamEmitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    IMP original = VCamOriginalIMPForObject(self);
    if (!sampleBuffer || sVCamHookRecursionDepth > 0) {
        if (original) ((void (*)(id, SEL, CMSampleBufferRef))original)(self, _cmd, sampleBuffer);
        return;
    }

    sVCamHookRecursionDepth++;
    @try {
        unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
        if (mediaType == 'vide') {
            CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (imageBuffer) {
                uint64_t frameCount = __atomic_add_fetch(&sVCamHookFrameCount, 1, __ATOMIC_RELAXED);
                if (frameCount == 1) {
                    NSString *dimensions = [NSString stringWithFormat:@"%zux%zu",
                        CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer)];
                    VCamSetRuntimeStatus(@"cameraFramesSeen", @YES);
                    VCamSetRuntimeStatus(@"firstCameraFrameAt", [NSDate date]);
                    VCamSetRuntimeStatus(@"cameraFrameSize", dimensions);
                    NSLog(@"[VCam] first video frame reached %@ (%@)", NSStringFromClass(object_getClass(self)), dimensions);
                }
                if (frameCount == 1 || (frameCount % 30) == 0) {
                    VCamSetRuntimeStatus(@"cameraHookFrameCount", @(frameCount));
                    VCamSetRuntimeStatus(@"cameraHookLastFrameAt", [NSDate date]);
                }

                @autoreleasepool {
                    loadReplacementMedia();
                    CVReturn lockResult = CVPixelBufferLockBaseAddress(imageBuffer, 0);
                    if (lockResult == kCVReturnSuccess) {
                        @try {
                            drawReplacementOntoBuffer(imageBuffer);
                        } @catch (NSException *exception) {
                            VCamSetRuntimeStatus(@"renderError", exception.reason ?: @"Unknown render exception");
                            NSLog(@"[VCam] Failed to render replacement media: %@", exception);
                        } @finally {
                            CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
                        }
                    } else {
                        VCamSetRuntimeStatus(@"renderError",
                            [NSString stringWithFormat:@"Camera pixel buffer lock failed: %d", lockResult]);
                    }
                }
            }
        }
        // Keep the recursion guard active while forwarding. A subclass IMP
        // may call super, which would otherwise process the same frame twice.
        if (original) ((void (*)(id, SEL, CMSampleBufferRef))original)(self, _cmd, sampleBuffer);
    } @catch (NSException *exception) {
        VCamSetRuntimeStatus(@"hookError", exception.reason ?: @"Unknown hook exception");
        NSLog(@"[VCam] camera hook exception: %@", exception);
    } @finally {
        sVCamHookRecursionDepth--;
    }
}

static BOOL VCamClassIsBWNodeOutputSubclass(Class candidate, Class baseClass) {
    for (Class current = candidate; current; current = class_getSuperclass(current)) {
        if (current == baseClass) return YES;
    }
    return NO;
}

static BOOL VCamClassImplementsSelectorDirectly(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}



// -----------------------------------------------------------------------------
// Per-app AVFoundation fallback, adapted from Five-great/ios-vcam.
// Hook the actual delegate class registered with AVCaptureVideoDataOutput.
// This is deliberately separate from the mediaserverd BWNodeOutput path.
// -----------------------------------------------------------------------------

static void *sAVFoundationHandle = NULL;
static IMP sOriginalSetSampleBufferDelegate = NULL;
static NSMutableDictionary<NSString *, NSValue *> *sAppDelegateOriginalIMPs;
static NSMutableSet<NSString *> *sAppHookedDelegateClasses;
static BOOL sAppCaptureHookInstalled = NO;
static NSUInteger sAppCaptureHookAttempts = 0;
static uint64_t sAppCaptureFrameCount = 0;
static __thread int sAppCaptureRecursionDepth = 0;

static IMP VCamAppOriginalIMPForObject(id object) {
    Class cls = object_getClass(object);
    @synchronized (sAppDelegateOriginalIMPs) {
        for (Class current = cls; current; current = class_getSuperclass(current)) {
            NSValue *value = sAppDelegateOriginalIMPs[NSStringFromClass(current)];
            if (value) return (IMP)value.pointerValue;
        }
    }
    return NULL;
}

static void VCamAppCaptureOutput(id self, SEL _cmd, AVCaptureOutput *output,
                                 CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    IMP original = VCamAppOriginalIMPForObject(self);
    if (!original) return;
    if (!sampleBuffer || sAppCaptureRecursionDepth > 0) {
        ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))original)
            (self, _cmd, output, sampleBuffer, connection);
        return;
    }

    sAppCaptureRecursionDepth++;
    @try {
        CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (imageBuffer) {
            uint64_t count = __atomic_add_fetch(&sAppCaptureFrameCount, 1, __ATOMIC_RELAXED);
            if (count == 1) {
                NSLog(@"[VCam] AVFoundation delegate path ACTIVE in %@ (%zux%zu)",
                      NSProcessInfo.processInfo.processName,
                      CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer));
            }
            @autoreleasepool {
                loadReplacementMedia();
                CVReturn lockResult = CVPixelBufferLockBaseAddress(imageBuffer, 0);
                if (lockResult == kCVReturnSuccess) {
                    @try {
                        drawReplacementOntoBuffer(imageBuffer);
                    } @catch (NSException *exception) {
                        NSLog(@"[VCam] app delegate render exception: %@", exception);
                    } @finally {
                        CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
                    }
                } else if (count == 1) {
                    NSLog(@"[VCam] app delegate pixel buffer lock failed: %d", lockResult);
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[VCam] app capture callback exception: %@", exception);
    } @finally {
        sAppCaptureRecursionDepth--;
    }

    ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))original)
        (self, _cmd, output, sampleBuffer, connection);
}

static void VCamHookAppDelegate(id delegate) {
    if (!delegate) return;
    SEL callback = sel_registerName("captureOutput:didOutputSampleBuffer:fromConnection:");
    Class delegateClass = object_getClass(delegate);
    Class implementationClass = Nil;

    // Hook the first class in the delegate's inheritance chain that owns the
    // callback. This catches concrete app delegates instead of only NSObject.
    for (Class current = delegateClass; current; current = class_getSuperclass(current)) {
        if (VCamClassImplementsSelectorDirectly(current, callback)) {
            implementationClass = current;
            break;
        }
    }
    if (!implementationClass) return;

    NSString *className = NSStringFromClass(implementationClass);
    if (!sAppDelegateOriginalIMPs) sAppDelegateOriginalIMPs = [NSMutableDictionary dictionary];
    if (!sAppHookedDelegateClasses) sAppHookedDelegateClasses = [NSMutableSet set];
    @synchronized (sAppHookedDelegateClasses) {
        if ([sAppHookedDelegateClasses containsObject:className]) return;
        IMP original = NULL;
        MSHookMessageEx(implementationClass, callback, (IMP)VCamAppCaptureOutput, &original);
        if (original) {
            sAppDelegateOriginalIMPs[className] = [NSValue valueWithPointer:original];
            [sAppHookedDelegateClasses addObject:className];
            NSLog(@"[VCam] hooked AVCapture delegate class %@", className);
        }
    }
}

static void VCamSetSampleBufferDelegate(id self, SEL _cmd,
                                        id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate,
                                        dispatch_queue_t queue) {
    if (sOriginalSetSampleBufferDelegate) {
        ((void (*)(id, SEL, id, dispatch_queue_t))sOriginalSetSampleBufferDelegate)(self, _cmd, delegate, queue);
    }
    if (delegate) VCamHookAppDelegate(delegate);
}

static void VCamTryInstallAppCaptureHooks(void) {
    if (sAppCaptureHookInstalled) return;
    sAppCaptureHookAttempts++;

    if (!sAVFoundationHandle) {
        sAVFoundationHandle = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
                                     RTLD_NOW | RTLD_GLOBAL);
    }

    Class outputClass = objc_getClass("AVCaptureVideoDataOutput");
    SEL setter = sel_registerName("setSampleBufferDelegate:queue:");
    Method method = outputClass ? class_getInstanceMethod(outputClass, setter) : NULL;
    if (method) {
        MSHookMessageEx(outputClass, setter, (IMP)VCamSetSampleBufferDelegate,
                        &sOriginalSetSampleBufferDelegate);
        sAppCaptureHookInstalled = (sOriginalSetSampleBufferDelegate != NULL);
        if (sAppCaptureHookInstalled) {
            NSLog(@"[VCam] AVFoundation app-level capture hook installed in %@",
                  NSProcessInfo.processInfo.processName);
            return;
        }
    }

    if (sAppCaptureHookAttempts < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            VCamTryInstallAppCaptureHooks();
        });
    } else {
        NSLog(@"[VCam] AVFoundation app-level hook unavailable in %@ (class=%@)",
              NSProcessInfo.processInfo.processName, outputClass ? @"present" : @"missing");
    }
}

static void VCamTryInstallCaptureHook(void) {
    if (sVCamHookInstalled) return;
    sVCamHookAttempts++;

    if (!sCMCaptureHandle) {
        sCMCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW | RTLD_GLOBAL);
        if (!sCMCaptureHandle) {
            sCMCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework", RTLD_NOW | RTLD_GLOBAL);
        }
    }

    Class baseClass = objc_getClass("BWNodeOutput");
    SEL selector = sel_registerName("emitSampleBuffer:");
    if (!baseClass || !class_getInstanceMethod(baseClass, selector)) {
        VCamSetRuntimeStatus(@"hookState", baseClass ? @"selector-not-found" : @"class-not-found");
        VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
        if (sVCamHookAttempts < 30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ VCamTryInstallCaptureHook(); });
        } else {
            VCamSetRuntimeStatus(@"hookState", @"failed");
        }
        return;
    }

    if (!sOriginalIMPs) sOriginalIMPs = [NSMutableDictionary dictionary];
    if (!sHookedClasses) sHookedClasses = [NSMutableSet set];

    int classCount = objc_getClassList(NULL, 0);
    if (classCount > 0) {
        Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
        classCount = objc_getClassList(classes, classCount);
        NSUInteger installedCount = 0;
        for (int i = 0; i < classCount; i++) {
            Class candidate = classes[i];
            if (!candidate || !VCamClassIsBWNodeOutputSubclass(candidate, baseClass)) continue;
            if (!VCamClassImplementsSelectorDirectly(candidate, selector)) continue;

            NSString *className = NSStringFromClass(candidate);
            if ([sHookedClasses containsObject:className]) continue;
            Method method = class_getInstanceMethod(candidate, selector);
            if (!method) continue;

            IMP original = NULL;
            MSHookMessageEx(candidate, selector, (IMP)VCamEmitSampleBuffer, &original);
            if (original) {
                sOriginalIMPs[className] = [NSValue valueWithPointer:original];
                [sHookedClasses addObject:className];
                installedCount++;
                NSLog(@"[VCam] hooked %@ -[%@ emitSampleBuffer:]", className, className);
            }
        }
        free(classes);
        VCamSetRuntimeStatus(@"hookedClassCount", @(sHookedClasses.count));
        VCamSetRuntimeStatus(@"hookInstallPassCount", @(installedCount));
    }

    sVCamHookInstalled = [sHookedClasses containsObject:@"BWNodeOutput"] || sHookedClasses.count > 0;
    VCamSetRuntimeStatus(@"hookState", sVCamHookInstalled ? @"installed" : @"no-concrete-implementations");
    VCamSetRuntimeStatus(@"hookInstalledAt", [NSDate date]);
    VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
    NSLog(@"[VCam] BWNodeOutput hook scan complete: %lu class(es) hooked",
          (unsigned long)sHookedClasses.count);

    // Re-scan periodically during daemon startup: camera node subclasses may
    // only be registered after the private capture graph is initialized.
    if (sVCamHookAttempts < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ VCamTryInstallCaptureHook(); });
    }
}

%ctor {
    @autoreleasepool {
        NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString;
        if ([processName isEqualToString:@"mediaserverd"]) {
            VCamResetRuntimeStatus();
            NSLog(@"[VCam] camera daemon tweak loaded; scanning BWNodeOutput implementations");
            VCamTryInstallCaptureHook();
        } else if (![processName isEqualToString:@"springboard"]) {
            NSLog(@"[VCam] app-level camera injection loaded in %@", processName);
            VCamTryInstallAppCaptureHooks();
        }
    }
}
