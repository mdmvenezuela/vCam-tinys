#import "image_utils.h"
#import "vcam_shared.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>
#import <AVFoundation/AVFoundation.h>

// System-wide camera hook. Each Objective-C implementation receives its own
// trampoline so a subclass calling super forwards to the superclass's own
// original IMP instead of re-entering the subclass replacement.
static void *sCMCaptureHandle = NULL;
static NSMutableSet<NSString *> *sHookedClasses;
static BOOL sVCamHookInstalled = NO;
static NSUInteger sVCamHookAttempts = 0;
static uint64_t sVCamHookFrameCount = 0;
static uint64_t sVCamEmitCallCount = 0;
static __thread int sVCamHookRecursionDepth = 0;
static BOOL sVCamHookScanScheduled = NO;

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

static BOOL VCamClassDescendsFrom(Class candidate, Class ancestor) {
    if (!candidate || !ancestor || candidate == ancestor) return NO;
    for (Class parent = class_getSuperclass(candidate); parent; parent = class_getSuperclass(parent)) {
        if (parent == ancestor) return YES;
    }
    return NO;
}

static void VCamProcessCameraSampleBuffer(id output, CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer) return;

    uint64_t callbackCount = __atomic_add_fetch(&sVCamEmitCallCount, 1, __ATOMIC_RELAXED);
    if (callbackCount == 1 || (callbackCount % 30) == 0) {
        VCamSetRuntimeStatus(@"cameraEmitCallbackCount", @(callbackCount));
        if (callbackCount == 1) {
            VCamSetRuntimeStatus(@"firstEmitCallbackAt", [NSDate date]);
            NSLog(@"[VCam] emitSampleBuffer callback reached: %@", NSStringFromClass(object_getClass(output)));
        }
    }

    unsigned int mediaType = 0;
    @try {
        mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(output, sel_registerName("mediaType"));
    } @catch (NSException *exception) {
        VCamSetRuntimeStatus(@"hookError", [NSString stringWithFormat:@"mediaType: %@", exception.reason ?: @"unknown"]);
        return;
    }
    if (mediaType != 'vide') return;

    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;

    uint64_t frameCount = __atomic_add_fetch(&sVCamHookFrameCount, 1, __ATOMIC_RELAXED);
    if (frameCount == 1) {
        NSString *dimensions = [NSString stringWithFormat:@"%zux%zu",
            CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer)];
        VCamSetRuntimeStatus(@"cameraFramesSeen", @YES);
        VCamSetRuntimeStatus(@"firstCameraFrameAt", [NSDate date]);
        VCamSetRuntimeStatus(@"cameraFrameSize", dimensions);
        NSLog(@"[VCam] first video frame intercepted by %@ (%@)",
              NSStringFromClass(object_getClass(output)), dimensions);
    }
    if (frameCount == 1 || (frameCount % 30) == 0) {
        VCamSetRuntimeStatus(@"cameraHookFrameCount", @(frameCount));
        VCamSetRuntimeStatus(@"cameraHookLastFrameAt", [NSDate date]);
    }

    @autoreleasepool {
        loadReplacementMedia();
        @try {
            drawReplacementOntoBuffer(imageBuffer);
        } @catch (NSException *exception) {
            VCamSetRuntimeStatus(@"renderError", exception.reason ?: @"Unknown render exception");
            NSLog(@"[VCam] Failed to render replacement media: %@", exception);
        }
    }
}

static BOOL VCamInstallCameraMethodHook(Class candidate, SEL selector) {
    NSString *className = NSStringFromClass(candidate);
    if (className.length == 0) return NO;
    if (!sHookedClasses) sHookedClasses = [NSMutableSet set];

    @synchronized (sHookedClasses) {
        if ([sHookedClasses containsObject:className]) return NO;

        Method method = class_getInstanceMethod(candidate, selector);
        if (!method) return NO;

        __block IMP originalIMP = method_getImplementation(method);
        IMP replacementIMP = imp_implementationWithBlock(^void(id object, CMSampleBufferRef sampleBuffer) {
            IMP next = originalIMP;
            if (!next) return;

            BOOL isOutermostCall = (sVCamHookRecursionDepth == 0);
            if (isOutermostCall) {
                sVCamHookRecursionDepth++;
                @try {
                    VCamProcessCameraSampleBuffer(object, sampleBuffer);
                    ((void (*)(id, SEL, CMSampleBufferRef))next)(object, selector, sampleBuffer);
                } @finally {
                    sVCamHookRecursionDepth--;
                }
            } else {
                // A hooked subclass called super. Skip a second render, but
                // forward to this class's captured original implementation.
                ((void (*)(id, SEL, CMSampleBufferRef))next)(object, selector, sampleBuffer);
            }
        });

        IMP substrateOriginal = NULL;
        MSHookMessageEx(candidate, selector, replacementIMP, &substrateOriginal);
        if (!substrateOriginal) {
            imp_removeBlock(replacementIMP);
            return NO;
        }

        originalIMP = substrateOriginal;
        [sHookedClasses addObject:className];
        NSLog(@"[VCam] installed class-specific BWNodeOutput trampoline: %@ original=%p",
              className, substrateOriginal);
        return YES;
    }
}

static void VCamTryInstallCaptureHook(void);

static void VCamScheduleNextHookScan(void) {
    if (sVCamHookScanScheduled) return;
    sVCamHookScanScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            sVCamHookScanScheduled = NO;
            VCamTryInstallCaptureHook();
        }
    });
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
        VCamScheduleNextHookScan();
        return;
    }

    int allocatedClassCount = objc_getClassList(NULL, 0);
    Class *classes = allocatedClassCount > 0
        ? (Class *)calloc((size_t)allocatedClassCount, sizeof(Class)) : NULL;
    if (!classes) {
        VCamSetRuntimeStatus(@"hookState", @"class-list-unavailable");
        VCamScheduleNextHookScan();
        return;
    }
    int discoveredClassCount = objc_getClassList(classes, allocatedClassCount);
    int classCount = MIN(discoveredClassCount, allocatedClassCount);

    NSUInteger newlyInstalled = 0;
    // Hook the base class AND all loaded subclasses that directly override
    // emitSampleBuffer:. Per-class trampolines make super-calls safe.
    for (int i = 0; i < classCount; i++) {
        Class candidate = classes[i];
        if (!candidate) continue;
        if (candidate != baseClass && !VCamClassDescendsFrom(candidate, baseClass)) continue;
        if (!VCamClassImplementsSelectorDirectly(candidate, selector)) continue;
        if (VCamInstallCameraMethodHook(candidate, selector)) newlyInstalled++;
    }
    free(classes);

    NSUInteger totalHooked = 0;
    @synchronized (sHookedClasses) { totalHooked = sHookedClasses.count; }
    sVCamHookInstalled = (totalHooked > 0);
    VCamSetRuntimeStatus(@"hookState", sVCamHookInstalled ? @"installed-class-specific-hooks" : @"waiting-for-camera-node-implementations");
    VCamSetRuntimeStatus(@"hookedClassCount", @(totalHooked));
    VCamSetRuntimeStatus(@"hookInstallPassCount", @(sVCamHookAttempts));
    VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
    if (newlyInstalled > 0) {
        VCamSetRuntimeStatus(@"hookInstalledAt", [NSDate date]);
        NSLog(@"[VCam] scan %lu: %lu class hook(s) installed; %lu total",
              (unsigned long)sVCamHookAttempts, (unsigned long)newlyInstalled, (unsigned long)totalHooked);
    }

    // The graph can load output-node classes lazily after daemon startup.
    // Continue scanning after an initial install instead of declaring success.
    VCamScheduleNextHookScan();
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
