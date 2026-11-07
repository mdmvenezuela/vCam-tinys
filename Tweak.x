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

static void VCamDrawReplacementOnce(CMSampleBufferRef sampleBuffer, CVPixelBufferRef imageBuffer) {
    if (!sampleBuffer || !imageBuffer) return;

    // The same frame can traverse BWNodeOutput and then one or more sink nodes.
    // Tag its pixel buffer by presentation timestamp so the final sink can act
    // as a fallback after graph reconfiguration without rendering the same
    // camera frame twice.
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    NSString *frameMarker = nil;
    if (CMTIME_IS_VALID(pts) && CMTIME_IS_NUMERIC(pts) && pts.timescale > 0) {
        frameMarker = [NSString stringWithFormat:@"%lld/%d/%lld",
                       pts.value, pts.timescale, pts.epoch];
        CFTypeRef previousMarker = CVBufferGetAttachment(
            imageBuffer, CFSTR("com.mdmvenezuela.vcam.rendered-pts"), NULL);
        if (previousMarker && CFEqual(previousMarker, (__bridge CFStringRef)frameMarker)) {
            return;
        }
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

    if (frameMarker) {
        CVBufferSetAttachment(imageBuffer,
                              CFSTR("com.mdmvenezuela.vcam.rendered-pts"),
                              (__bridge CFStringRef)frameMarker,
                              kCVAttachmentMode_ShouldNotPropagate);
    }
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

    VCamDrawReplacementOnce(sampleBuffer, imageBuffer);
}

// Final camera sinks receive the exact buffers that are about to be displayed
// locally or sent to an AVCapture client. These hooks remain active when the
// still-photo shutter rebuilds/reconfigures the graph and a source output node
// changes underneath BWNodeOutput.
static IMP sOriginalImageQueueSinkRender = NULL;
static IMP sOriginalRemoteQueueSinkRender = NULL;
static IMP sOriginalStillImageSinkRender = NULL;
static BOOL sImageQueueSinkHookInstalled = NO;
static BOOL sRemoteQueueSinkHookInstalled = NO;
static BOOL sStillImageSinkHookInstalled = NO;
static uint64_t sLocalPreviewSinkFrameCount = 0;
static uint64_t sRemotePreviewSinkFrameCount = 0;
static uint64_t sStillPhotoSinkFrameCount = 0;

static void VCamProcessSinkSampleBuffer(id input,
                                        CMSampleBufferRef sampleBuffer,
                                        BOOL requireVideoMediaType,
                                        NSString *counterKey) {
    if (!sampleBuffer) return;

    if (requireVideoMediaType) {
        if (!input) return;
        unsigned int mediaType = 0;
        @try {
            mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(input, sel_registerName("mediaType"));
        } @catch (NSException *exception) {
            VCamSetRuntimeStatus(@"sinkHookError", exception.reason ?: @"Unable to read sink input mediaType");
            return;
        }
        if (mediaType != 'vide') return;
    }

    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        if (!requireVideoMediaType) {
            VCamSetRuntimeStatus(@"stillPhotoSinkBufferHasPixelBuffer", @NO);
        }
        return;
    }

    uint64_t count = 0;
    if ([counterKey isEqualToString:@"cameraLocalPreviewSinkCount"]) {
        count = __atomic_add_fetch(&sLocalPreviewSinkFrameCount, 1, __ATOMIC_RELAXED);
    } else if ([counterKey isEqualToString:@"cameraRemotePreviewSinkCount"]) {
        count = __atomic_add_fetch(&sRemotePreviewSinkFrameCount, 1, __ATOMIC_RELAXED);
    } else {
        count = __atomic_add_fetch(&sStillPhotoSinkFrameCount, 1, __ATOMIC_RELAXED);
        VCamSetRuntimeStatus(@"stillPhotoSinkBufferHasPixelBuffer", @YES);
    }

    if (count == 1 || (count % 30) == 0) {
        VCamSetRuntimeStatus(counterKey, @(count));
        VCamSetRuntimeStatus(@"cameraSinkLastFrameAt", [NSDate date]);
        VCamSetRuntimeStatus(@"cameraFrameSize",
            [NSString stringWithFormat:@"%zux%zu",
             CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer)]);
        VCamSetRuntimeStatus(@"cameraFramesSeen", @YES);
    }

    VCamDrawReplacementOnce(sampleBuffer, imageBuffer);
}

static void VCamImageQueueSinkRender(id self, SEL _cmd,
                                     CMSampleBufferRef sampleBuffer, id input) {
    VCamProcessSinkSampleBuffer(input, sampleBuffer, YES, @"cameraLocalPreviewSinkCount");
    if (sOriginalImageQueueSinkRender) {
        ((void (*)(id, SEL, CMSampleBufferRef, id))sOriginalImageQueueSinkRender)
            (self, _cmd, sampleBuffer, input);
    }
}

static void VCamRemoteQueueSinkRender(id self, SEL _cmd,
                                      CMSampleBufferRef sampleBuffer, id input) {
    VCamProcessSinkSampleBuffer(input, sampleBuffer, YES, @"cameraRemotePreviewSinkCount");
    if (sOriginalRemoteQueueSinkRender) {
        ((void (*)(id, SEL, CMSampleBufferRef, id))sOriginalRemoteQueueSinkRender)
            (self, _cmd, sampleBuffer, input);
    }
}

static void VCamStillImageSinkRender(id self, SEL _cmd,
                                     CMSampleBufferRef sampleBuffer, id input) {
    // The still sink may receive either a pixel-buffer photo or a compressed
    // sample buffer. Only mutate the former; compressed JPEG/HEIF samples are
    // left untouched rather than being treated as camera preview buffers.
    VCamProcessSinkSampleBuffer(input, sampleBuffer, NO, @"cameraStillPhotoSinkCount");
    if (sOriginalStillImageSinkRender) {
        ((void (*)(id, SEL, CMSampleBufferRef, id))sOriginalStillImageSinkRender)
            (self, _cmd, sampleBuffer, input);
    }
}

static void VCamTryInstallSinkHooks(void) {
    SEL renderSelector = sel_registerName("renderSampleBuffer:forInput:");

    Class localSinkClass = objc_getClass("BWImageQueueSinkNode");
    if (localSinkClass && !sImageQueueSinkHookInstalled &&
        VCamClassImplementsSelectorDirectly(localSinkClass, renderSelector)) {
        IMP original = NULL;
        MSHookMessageEx(localSinkClass, renderSelector, (IMP)VCamImageQueueSinkRender, &original);
        if (original) {
            sOriginalImageQueueSinkRender = original;
            sImageQueueSinkHookInstalled = YES;
            VCamSetRuntimeStatus(@"localPreviewSinkHookState", @"installed");
            NSLog(@"[VCam] installed final local preview sink hook");
        }
    }

    Class remoteSinkClass = objc_getClass("BWRemoteQueueSinkNode");
    if (remoteSinkClass && !sRemoteQueueSinkHookInstalled &&
        VCamClassImplementsSelectorDirectly(remoteSinkClass, renderSelector)) {
        IMP original = NULL;
        MSHookMessageEx(remoteSinkClass, renderSelector, (IMP)VCamRemoteQueueSinkRender, &original);
        if (original) {
            sOriginalRemoteQueueSinkRender = original;
            sRemoteQueueSinkHookInstalled = YES;
            VCamSetRuntimeStatus(@"remotePreviewSinkHookState", @"installed");
            NSLog(@"[VCam] installed final remote preview sink hook");
        }
    }

    Class stillSinkClass = objc_getClass("BWStillImageSampleBufferSinkNode");
    if (stillSinkClass && !sStillImageSinkHookInstalled &&
        VCamClassImplementsSelectorDirectly(stillSinkClass, renderSelector)) {
        IMP original = NULL;
        MSHookMessageEx(stillSinkClass, renderSelector, (IMP)VCamStillImageSinkRender, &original);
        if (original) {
            sOriginalStillImageSinkRender = original;
            sStillImageSinkHookInstalled = YES;
            VCamSetRuntimeStatus(@"stillPhotoSinkHookState", @"installed");
            NSLog(@"[VCam] installed final still-photo sink hook");
        }
    }

    VCamSetRuntimeStatus(@"localPreviewSinkHookState",
        sImageQueueSinkHookInstalled ? @"installed" : (localSinkClass ? @"method-not-found" : @"class-not-found"));
    VCamSetRuntimeStatus(@"remotePreviewSinkHookState",
        sRemoteQueueSinkHookInstalled ? @"installed" : (remoteSinkClass ? @"method-not-found" : @"class-not-found"));
    VCamSetRuntimeStatus(@"stillPhotoSinkHookState",
        sStillImageSinkHookInstalled ? @"installed" : (stillSinkClass ? @"method-not-found" : @"class-not-found"));
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

    // Install sink-side hooks independently of BWNodeOutput. The sink classes
    // can exist even when the source callback implementation is unavailable.
    VCamTryInstallSinkHooks();

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
