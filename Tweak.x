#import "image_utils.h"
#import "vcam_shared.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>
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

// Return YES only when this class declares the selector itself, rather than inheriting it.
// class_getInstanceMethod() is not sufficient here because it also searches superclasses.
static BOOL VCamClassImplementsSelectorDirectly(Class cls, SEL selector) {
    if (!cls || !selector) return NO;
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    BOOL found = NO;
    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

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
                    // CIContext can write through the GPU/IOSurface path.
                    // Do not CPU-lock a camera-owned buffer before CIContext renders into it.
                    @try {
                        drawReplacementOntoBuffer(imageBuffer);
                    } @catch (NSException *exception) {
                        VCamSetRuntimeStatus(@"renderError", exception.reason ?: @"Unknown render exception");
                        NSLog(@"[VCam] Failed to render replacement media: %@", exception);
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
                // CIContext writes through the pixel buffer/IOSurface; a CPU
                // base-address lock is not required for this GPU render path.
                @try {
                    drawReplacementOntoBuffer(imageBuffer);
                } @catch (NSException *exception) {
                    NSLog(@"[VCam] app delegate render exception: %@", exception);
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

static BOOL VCamHasOverridingDescendant(Class candidate, Class *classes, int classCount, SEL selector) {
    for (int i = 0; i < classCount; i++) {
        Class current = classes[i];
        if (!current || current == candidate) continue;
        BOOL isDescendant = NO;
        for (Class parent = class_getSuperclass(current); parent; parent = class_getSuperclass(parent)) {
            if (parent == candidate) { isDescendant = YES; break; }
        }
        if (isDescendant && VCamClassImplementsSelectorDirectly(current, selector)) return YES;
    }
    return NO;
}

static void VCamTryInstallCaptureHook(void) {
    sVCamHookAttempts++;

    if (!sCMCaptureHandle) {
        sCMCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW | RTLD_GLOBAL);
        if (!sCMCaptureHandle) {
            sCMCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework", RTLD_NOW | RTLD_GLOBAL);
        }
    }

    Class baseClass = objc_getClass("BWNodeOutput");
    SEL selector = sel_registerName("emitSampleBuffer:");
    Method baseMethod = baseClass ? class_getInstanceMethod(baseClass, selector) : NULL;
    if (!baseClass || !baseMethod) {
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
    Class *classes = classCount > 0 ? (Class *)calloc((size_t)classCount, sizeof(Class)) : NULL;
    if (!classes) {
        VCamSetRuntimeStatus(@"hookState", @"class-list-unavailable");
        return;
    }
    classCount = objc_getClassList(classes, classCount);
    NSUInteger installedThisPass = 0;
    NSUInteger eligibleCount = 0;

    // Hook only leaf implementations. If an overridden method calls super,
    // the superclass remains untouched and its original implementation runs
    // normally. Hooking both parent and child with one replacement IMP causes
    // the child original to re-enter the replacement through super.
    for (int i = 0; i < classCount; i++) {
        Class candidate = classes[i];
        if (!candidate || candidate == baseClass) continue;

        BOOL descendsFromBase = NO;
        for (Class parent = class_getSuperclass(candidate); parent; parent = class_getSuperclass(parent)) {
            if (parent == baseClass) { descendsFromBase = YES; break; }
        }
        if (!descendsFromBase || !VCamClassImplementsSelectorDirectly(candidate, selector)) continue;
        if (VCamHasOverridingDescendant(candidate, classes, classCount, selector)) continue;

        NSString *className = NSStringFromClass(candidate);
        @synchronized (sOriginalIMPs) {
            if ([sHookedClasses containsObject:className]) continue;
        }
        eligibleCount++;

        IMP original = NULL;
        MSHookMessageEx(candidate, selector, (IMP)VCamEmitSampleBuffer, &original);
        if (original) {
            @synchronized (sOriginalIMPs) {
                sOriginalIMPs[className] = [NSValue valueWithPointer:original];
                [sHookedClasses addObject:className];
            }
            installedThisPass++;
            NSLog(@"[VCam] hooked leaf camera node %@ original=%p", className, original);
        }
    }
    free(classes);

    NSUInteger totalHooked = 0;
    @synchronized (sOriginalIMPs) { totalHooked = sHookedClasses.count; }
    if (totalHooked > 0) {
        sVCamHookInstalled = YES;
        VCamSetRuntimeStatus(@"hookState", @"installed-concrete-leaf-classes");
        VCamSetRuntimeStatus(@"hookedClassCount", @(totalHooked));
        VCamSetRuntimeStatus(@"hookInstallPassCount", @(sVCamHookAttempts));
        VCamSetRuntimeStatus(@"hookInstalledAt", [NSDate date]);
        VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
        NSLog(@"[VCam] camera hook pass complete: %lu leaf implementation(s), %lu newly installed",
              (unsigned long)totalHooked, (unsigned long)installedThisPass);
        return;
    }

    VCamSetRuntimeStatus(@"hookState", eligibleCount ? @"install-failed-no-original-imp" : @"waiting-for-concrete-camera-node");
    VCamSetRuntimeStatus(@"hookedClassCount", @0);
    VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
    if (sVCamHookAttempts < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ VCamTryInstallCaptureHook(); });
    } else {
        VCamSetRuntimeStatus(@"hookState", @"no-concrete-camera-node-found");
    }
}
%ctor {
    @autoreleasepool {
        NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString;
        if ([processName isEqualToString:@"mediaserverd"]) {
            VCamResetRuntimeStatus();
            NSLog(@"[VCam] camera daemon tweak loaded; scanning concrete BWNodeOutput camera nodes");
            VCamTryInstallCaptureHook();
        } else if (![processName isEqualToString:@"springboard"]) {
            NSLog(@"[VCam] app-level camera injection loaded in %@", processName);
            VCamTryInstallAppCaptureHooks();
        }
    }
}
