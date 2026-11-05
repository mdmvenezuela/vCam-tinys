#import "image_utils.h"
#import "vcam_shared.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

// BWNodeOutput is declared by Apple's private CMCapture framework. On some
// iOS builds it is not registered when a camera daemon first loads third-party
// tweaks. Load CMCapture explicitly, then install the Logos group only after
// the class and selector are confirmed to exist.
%group VCamCaptureHooks

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    static uint64_t sVCamHookFrameCount = 0;
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType != 'vide') {
        %orig(sampleBuffer);
        return;
    }

    static dispatch_once_t sFirstVideoBuffer;
    dispatch_once(&sFirstVideoBuffer, ^{
        CVPixelBufferRef firstBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        NSString *dimensions = firstBuffer
            ? [NSString stringWithFormat:@"%zux%zu", CVPixelBufferGetWidth(firstBuffer), CVPixelBufferGetHeight(firstBuffer)]
            : @"unavailable";
        VCamSetRuntimeStatus(@"cameraFramesSeen", @YES);
        VCamSetRuntimeStatus(@"firstCameraFrameAt", [NSDate date]);
        VCamSetRuntimeStatus(@"cameraFrameSize", dimensions);
        NSLog(@"[VCam] first video frame reached BWNodeOutput (%@)", dimensions);
    });

    uint64_t hookFrameCount = __atomic_add_fetch(&sVCamHookFrameCount, 1, __ATOMIC_RELAXED);
    if (hookFrameCount == 1 || (hookFrameCount % 30) == 0) {
        VCamSetRuntimeStatus(@"cameraHookFrameCount", @(hookFrameCount));
        VCamSetRuntimeStatus(@"cameraHookLastFrameAt", [NSDate date]);
    }

    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        %orig(sampleBuffer);
        return;
    }

    @autoreleasepool {
        loadReplacementMedia();
        // CIContext renders directly to CVPixelBuffer. Locking the base address
        // is only needed for CPU byte access and can force costly synchronization
        // on GPU-backed camera buffers, causing preview stutter.
        @try {
            drawReplacementOntoBuffer(imageBuffer);
        } @catch (NSException *exception) {
            VCamSetRuntimeStatus(@"renderError", exception.reason ?: @"Unknown render exception");
            NSLog(@"[VCam] Failed to render replacement media: %@", exception);
        }
    }

    %orig(sampleBuffer);
}

%end
%end

static void *sCMCaptureHandle = NULL;
static BOOL sVCamHookInstalled = NO;
static NSUInteger sVCamHookAttempts = 0;
static void VCamTryInstallCaptureHook(void) {
    if (sVCamHookInstalled) return;
    sVCamHookAttempts++;

    if (!sCMCaptureHandle) {
        sCMCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW | RTLD_GLOBAL);
        if (!sCMCaptureHandle) {
            // Keep the fallback for OS builds exposing the framework through a different dyld path.
            sCMCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework", RTLD_NOW | RTLD_GLOBAL);
        }
    }

    Class outputClass = objc_getClass("BWNodeOutput");
    SEL outputSelector = sel_registerName("emitSampleBuffer:");
    Method outputMethod = outputClass ? class_getInstanceMethod(outputClass, outputSelector) : NULL;

    if (outputClass && outputMethod) {
        %init(VCamCaptureHooks);
        sVCamHookInstalled = YES;
        VCamSetRuntimeStatus(@"hookState", @"installed");
        VCamSetRuntimeStatus(@"hookInstalledAt", [NSDate date]);
        VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
        NSLog(@"[VCam] installed BWNodeOutput emitSampleBuffer: hook from CMCapture");
        return;
    }

    NSString *state = outputClass ? @"selector-not-found" : @"class-not-found";
    VCamSetRuntimeStatus(@"hookState", state);
    VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
    if (!outputClass) {
        const char *error = dlerror();
        VCamSetRuntimeStatus(@"hookDetail", error ? [NSString stringWithUTF8String:error] : @"BWNodeOutput is not registered yet");
    } else {
        VCamSetRuntimeStatus(@"hookDetail", @"BWNodeOutput exists but emitSampleBuffer: is missing");
    }

    // Retry while the camera daemon is still bringing up its capture framework stack.
    if (sVCamHookAttempts < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            VCamTryInstallCaptureHook();
        });
    } else {
        VCamSetRuntimeStatus(@"hookState", @"failed");
    }
}

%ctor {
    @autoreleasepool {
        VCamResetRuntimeStatus();
        NSString *processName = NSProcessInfo.processInfo.processName;
        NSLog(@"[VCam] camera daemon tweak loaded in %@; CMCapture hook installation starting", processName);
        VCamTryInstallCaptureHook();
    }
}
