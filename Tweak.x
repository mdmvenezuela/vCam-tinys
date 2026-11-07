#import "image_utils.h"
#import "vcam_shared.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

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
        VCamResetRuntimeStatus();
        NSString *processName = NSProcessInfo.processInfo.processName;
        NSLog(@"[VCam] camera daemon tweak loaded in %@; scanning BWNodeOutput implementations", processName);
        VCamTryInstallCaptureHook();
    }
}
