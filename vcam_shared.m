#import "vcam_shared.h"
#import <sys/stat.h>
#import <notify.h>
#import <time.h>
#import <dispatch/dispatch.h>

NSString * const VCamPreferenceDomain = @"com.tinysweet.vcamios";
NSString * const VCamMediaPathKey = @"MediaPath";
NSString * const VCamMediaTypeKey = @"MediaType";
NSString * const VCamEnabledKey = @"Enabled";
NSString * const VCamOffsetXKey = @"OffsetX";
NSString * const VCamOffsetYKey = @"OffsetY";
NSString * const VCamRotationKey = @"Rotation";
NSString * const VCamZoomKey = @"Zoom";
NSString * const VCamVideoPausedKey = @"VideoPaused";
NSString * const VCamRuntimeVersion = @"0.1.48";

static NSString *VCamPreferencesDirectory(void) {
    // Keep persistent preferences outside /tmp; only the selected media is temporary.
    return @"/var/mobile/Media/VCam";
}

static NSString *VCamPreferencesFilePath(void) {
    return [VCamPreferencesDirectory() stringByAppendingPathComponent:@"settings.plist"];
}

// Enabled is mirrored to a small file beside the selected media. This is the
// same filesystem location mediaserverd has already proven it can read.
static NSString *VCamEnabledMarkerPath(void) {
    return [VCamMediaDirectory() stringByAppendingPathComponent:@".replacement-enabled"];
}

static NSNumber *VCamReadEnabledMarker(void) {
    NSString *contents = [NSString stringWithContentsOfFile:VCamEnabledMarkerPath()
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    contents = [contents stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([contents isEqualToString:@"1"]) return @YES;
    if ([contents isEqualToString:@"0"]) return @NO;
    return nil;
}

static void VCamWriteEnabledMarker(id value) {
    NSString *directory = VCamMediaDirectory();
    NSError *error = nil;
    BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                              withIntermediateDirectories:YES
                                                               attributes:@{ NSFilePosixPermissions: @0755 }
                                                                    error:&error];
    if (!created) {
        NSLog(@"[VCam] cannot prepare enabled marker directory %@: %@", directory, error);
        return;
    }
    chmod(directory.fileSystemRepresentation, 0755);
    NSString *path = VCamEnabledMarkerPath();
    if (!value) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return;
    }
    NSString *contents = [value respondsToSelector:@selector(boolValue)] && [value boolValue] ? @"1" : @"0";
    if ([contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        chmod(path.fileSystemRepresentation, 0644);
    } else {
        NSLog(@"[VCam] cannot publish enabled marker %@: %@", path, error);
    }
}

// On iOS 17.6 the supported camera path for this tweak is mediaserverd.
// Do not report cameracaptured as a required daemon on OS versions where it
// is not part of the camera delivery path.
static NSArray<NSString *> *VCamCameraDaemonNames(void) {
    return @[@"mediaserverd"];
}

static NSString *VCamCurrentDaemonName(void) {
    NSString *name = NSProcessInfo.processInfo.processName.lowercaseString;
    for (NSString *candidate in VCamCameraDaemonNames()) {
        if ([name isEqualToString:candidate]) return candidate;
    }
    return name.length ? name : @"unknown";
}

static NSString *VCamRuntimeStatusDirectory(void) {
    // Keep runtime diagnostics in the established location. Version 0.1.40
    // moved this plist beside media, but SpringBoard could no longer read the
    // daemon hook/media details there. Heartbeat and counters remain on notify.
    return @"/tmp/VCamStatus";
}

static NSString *VCamRuntimeStatusFilePathForProcess(NSString *processName) {
    NSString *filename = [NSString stringWithFormat:@"runtime-status-%@.plist", processName];
    return [VCamRuntimeStatusDirectory() stringByAppendingPathComponent:filename];
}

static BOOL VCamEnsureRuntimeStatusDirectory(void) {
    NSString *directory = VCamRuntimeStatusDirectory();
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                         withIntermediateDirectories:YES
                                                          attributes:@{ NSFilePosixPermissions: @0777 }
                                                               error:&error];
    if (ok) chmod(directory.fileSystemRepresentation, 0777);
    if (!ok) NSLog(@"[VCam] cannot create runtime status directory %@: %@", directory, error);
    return ok;
}

static NSDictionary *VCamReadRuntimeStatusForProcess(NSString *processName) {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:VCamRuntimeStatusFilePathForProcess(processName)];
    return [status isKindOfClass:[NSDictionary class]] ? status : @{};
}

static NSString *VCamHeartbeatName(NSString *processName) {
    return [NSString stringWithFormat:@"com.tinysweet.vcamios.heartbeat.%@", processName];
}

// Darwin notify state is shared by SpringBoard and mediaserverd even when
// RootHide gives the processes different filesystem views. Tokens themselves
// are process-local, so each process registers its own token for the same name.
static int VCamNotifyTokenForName(NSString *name) {
    static NSMutableDictionary<NSString *, NSNumber *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = [NSMutableDictionary dictionary];
    });

    @synchronized (tokens) {
        NSNumber *cached = tokens[name];
        if (cached) return cached.intValue;

        int token = NOTIFY_TOKEN_INVALID;
        uint32_t status = notify_register_check(name.UTF8String, &token);
        if (status != NOTIFY_STATUS_OK || token == NOTIFY_TOKEN_INVALID) {
            NSLog(@"[VCam] notify_register_check failed for %@: %u", name, status);
            return NOTIFY_TOKEN_INVALID;
        }
        tokens[name] = @(token);
        return token;
    }
}

static int VCamNotifyToken(NSString *processName) {
    return VCamNotifyTokenForName(VCamHeartbeatName(processName));
}

static NSString *VCamSettingStateName(NSString *key) {
    return [NSString stringWithFormat:@"%@.setting.%@", VCamPreferenceDomain, key];
}

static NSString *VCamSettingChunkStateName(NSString *key, NSUInteger chunkIndex) {
    return [NSString stringWithFormat:@"%@.chunk.%lu", VCamSettingStateName(key), (unsigned long)chunkIndex];
}

// Darwin notify state is a uint64 value. Store UTF-8 setting values as ordered
// 8-byte chunks, then publish the byte length last as the commit marker. This
// transports MediaPath across RootHide process filesystem views without relying
// on SpringBoard and mediaserverd seeing the same plist file.
static BOOL VCamReadPublishedStringSetting(NSString *key, NSString **valueOut) {
    int lengthToken = VCamNotifyTokenForName([VCamSettingStateName(key) stringByAppendingString:@".length"]);
    if (lengthToken == NOTIFY_TOKEN_INVALID) return NO;

    uint64_t encodedLength = 0;
    if (notify_get_state(lengthToken, &encodedLength) != NOTIFY_STATUS_OK || encodedLength == 0) return NO;
    if (encodedLength == UINT64_MAX) {
        if (valueOut) *valueOut = @"";
        return YES;
    }
    if (encodedLength > 4097) return NO;

    NSUInteger byteLength = (NSUInteger)(encodedLength - 1);
    NSMutableData *data = [NSMutableData dataWithLength:byteLength];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    NSUInteger chunkCount = (byteLength + 7) / 8;

    for (NSUInteger chunkIndex = 0; chunkIndex < chunkCount; chunkIndex++) {
        int token = VCamNotifyTokenForName(VCamSettingChunkStateName(key, chunkIndex));
        if (token == NOTIFY_TOKEN_INVALID) return NO;
        uint64_t chunkValue = 0;
        if (notify_get_state(token, &chunkValue) != NOTIFY_STATUS_OK) return NO;
        for (NSUInteger byteIndex = 0; byteIndex < 8; byteIndex++) {
            NSUInteger destinationIndex = chunkIndex * 8 + byteIndex;
            if (destinationIndex >= byteLength) break;
            bytes[destinationIndex] = (uint8_t)((chunkValue >> (byteIndex * 8)) & 0xff);
        }
    }

    NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!decoded) return NO;
    if (valueOut) *valueOut = decoded;
    return YES;
}

static void VCamPublishStringSetting(NSString *key, NSString *value) {
    NSData *data = [(value ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length > 4096) {
        NSLog(@"[VCam] setting %@ is too large for shared state", key);
        return;
    }

    int lengthToken = VCamNotifyTokenForName([VCamSettingStateName(key) stringByAppendingString:@".length"]);
    if (lengthToken == NOTIFY_TOKEN_INVALID || notify_set_state(lengthToken, UINT64_MAX) != NOTIFY_STATUS_OK) {
        NSLog(@"[VCam] failed to begin publishing shared setting %@", key);
        return;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger chunkCount = (data.length + 7) / 8;
    for (NSUInteger chunkIndex = 0; chunkIndex < chunkCount; chunkIndex++) {
        uint64_t chunkValue = 0;
        for (NSUInteger byteIndex = 0; byteIndex < 8; byteIndex++) {
            NSUInteger sourceIndex = chunkIndex * 8 + byteIndex;
            if (sourceIndex >= data.length) break;
            chunkValue |= ((uint64_t)bytes[sourceIndex]) << (byteIndex * 8);
        }
        int token = VCamNotifyTokenForName(VCamSettingChunkStateName(key, chunkIndex));
        if (token == NOTIFY_TOKEN_INVALID || notify_set_state(token, chunkValue) != NOTIFY_STATUS_OK) {
            NSLog(@"[VCam] failed to publish shared setting %@ chunk %lu", key, (unsigned long)chunkIndex);
            return;
        }
    }

    // Publish the length only after every chunk is written so readers never
    // interpret a partially updated path as a complete selection.
    if (notify_set_state(lengthToken, (uint64_t)data.length + 1) != NOTIFY_STATUS_OK) {
        NSLog(@"[VCam] failed to commit shared setting %@", key);
        return;
    }
    notify_post(VCamSettingStateName(key).UTF8String);
}

static NSString *VCamSerializeSettingValue(NSString *key, id value) {
    if (!value) return @"";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([key isEqualToString:VCamEnabledKey] || [key isEqualToString:VCamVideoPausedKey]) {
        return [value respondsToSelector:@selector(boolValue)] && [value boolValue] ? @"1" : @"0";
    }
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return [value description] ?: @"";
}

static id VCamDeserializeSettingValue(NSString *key, NSString *value) {
    if (value.length == 0) return nil;
    if ([key isEqualToString:VCamEnabledKey] || [key isEqualToString:VCamVideoPausedKey]) return @([value boolValue]);
    if ([key isEqualToString:VCamOffsetXKey] || [key isEqualToString:VCamOffsetYKey] || [key isEqualToString:VCamZoomKey]) return @([value doubleValue]);
    if ([key isEqualToString:VCamRotationKey]) return @([value integerValue]);
    return value;
}

static uint64_t VCamReadHeartbeatForProcess(NSString *processName) {
    int token = VCamNotifyToken(processName);
    if (token == NOTIFY_TOKEN_INVALID) return 0;
    uint64_t timestamp = 0;
    if (notify_get_state(token, &timestamp) != NOTIFY_STATUS_OK) return 0;
    return timestamp;
}

static void VCamPublishHeartbeatForProcess(NSString *processName) {
    int token = VCamNotifyToken(processName);
    if (token == NOTIFY_TOKEN_INVALID) return;
    uint64_t timestamp = (uint64_t)time(NULL);
    if (notify_set_state(token, timestamp) == NOTIFY_STATUS_OK) {
        notify_post(VCamHeartbeatName(processName).UTF8String);
    }
}

static BOOL VCamEnsurePreferencesDirectory(void) {
    NSString *directory = VCamPreferencesDirectory();
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                         withIntermediateDirectories:YES
                                                          attributes:@{ NSFilePosixPermissions: @0755 }
                                                               error:&error];
    if (ok) chmod(directory.fileSystemRepresentation, 0755);
    if (!ok) NSLog(@"[VCam] cannot create preferences directory %@: %@", directory, error);
    return ok;
}

id VCamCopySetting(NSString *key) {
    if (key.length == 0) return nil;

    // Prefer the shared marker for Enabled. It does not depend on notify tokens
    // being observed identically inside SpringBoard and RootHide daemons.
    if ([key isEqualToString:VCamEnabledKey]) {
        NSNumber *markerValue = VCamReadEnabledMarker();
        if (markerValue) return markerValue;
    }

    NSString *publishedValue = nil;
    if (VCamReadPublishedStringSetting(key, &publishedValue)) {
        id value = VCamDeserializeSettingValue(key, publishedValue);
        if ([key isEqualToString:VCamEnabledKey] && value) VCamWriteEnabledMarker(value);
        return value;
    }

    // Migration path for values written by earlier releases. The first process
    // that can still see the legacy plist republishes each value to Darwin notify.
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:VCamPreferencesFilePath()];
    id value = settings[key];
    if (value) {
        VCamPublishStringSetting(key, VCamSerializeSettingValue(key, value));
        if ([key isEqualToString:VCamEnabledKey]) VCamWriteEnabledMarker(value);
    }
    return value;
}

void VCamSetSetting(NSString *key, id value) {
    if (key.length == 0) return;
    NSString *path = VCamPreferencesFilePath();
    @synchronized (VCamPreferenceDomain) {
        NSMutableDictionary *settings = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
        if (!settings) settings = [NSMutableDictionary dictionary];
        if (value) settings[key] = value;
        else [settings removeObjectForKey:key];
        if (VCamEnsurePreferencesDirectory()) {
            BOOL didWrite = [settings writeToFile:path atomically:YES];
            if (didWrite) chmod(path.fileSystemRepresentation, 0644);
            else NSLog(@"[VCam] failed to write shared settings %@", path);
        }
    }

    // Mirror the critical ON/OFF switch to the shared media directory too.
    if ([key isEqualToString:VCamEnabledKey]) VCamWriteEnabledMarker(value);

    // Publish settings independently of the media file path on disk.
    // SpringBoard and mediaserverd consume the same Darwin notify state.
    VCamPublishStringSetting(key, VCamSerializeSettingValue(key, value));
}


// Publish the hot-path diagnostics through Darwin notify. /tmp can be presented
// through different RootHide filesystem views, while notify state is shared.
static NSString *VCamRuntimeNotifyName(NSString *key) {
    return [NSString stringWithFormat:@"%@.runtime.mediaserverd.%@", VCamPreferenceDomain, key];
}

static void VCamPublishRuntimeCounter(NSString *key, uint64_t value) {
    int token = VCamNotifyTokenForName(VCamRuntimeNotifyName(key));
    if (token == NOTIFY_TOKEN_INVALID) return;
    notify_set_state(token, value);
    notify_post(VCamRuntimeNotifyName(key).UTF8String);
}

static BOOL VCamTryReadRuntimeCounter(NSString *key, uint64_t *valueOut) {
    int token = VCamNotifyTokenForName(VCamRuntimeNotifyName(key));
    uint64_t value = 0;
    if (token == NOTIFY_TOKEN_INVALID || notify_get_state(token, &value) != NOTIFY_STATUS_OK) return NO;
    if (valueOut) *valueOut = value;
    return YES;
}

static uint64_t VCamRenderSkipCode(NSString *reason) {
    if ([reason isEqualToString:@"replacement-disabled"]) return 1;
    if ([reason isEqualToString:@"media-not-ready"]) return 2;
    if ([reason isEqualToString:@"render-context-unavailable"]) return 3;
    if ([reason isEqualToString:@"image-source-unavailable"]) return 4;
    if ([reason isEqualToString:@"video-frame-not-ready"]) return 5;
    if ([reason isEqualToString:@"camera-buffer-has-zero-size"]) return 6;
    return 0;
}

static NSString *VCamRenderSkipReasonForCode(uint64_t code) {
    switch (code) {
        case 1: return @"replacement-disabled";
        case 2: return @"media-not-ready";
        case 3: return @"render-context-unavailable";
        case 4: return @"image-source-unavailable";
        case 5: return @"video-frame-not-ready";
        case 6: return @"camera-buffer-has-zero-size";
        default: return nil;
    }
}

NSDictionary *VCamCopyRuntimeStatus(void) {
    NSMutableDictionary *daemonStatuses = [NSMutableDictionary dictionary];
    NSDictionary *newestStatus = nil;
    NSDate *newestDate = nil;
    uint64_t now = (uint64_t)time(NULL);

    for (NSString *processName in VCamCameraDaemonNames()) {
        NSMutableDictionary *status = [VCamReadRuntimeStatusForProcess(processName) mutableCopy];
        if (!status) status = [NSMutableDictionary dictionary];

        uint64_t heartbeat = VCamReadHeartbeatForProcess(processName);
        BOOL heartbeatCurrent = heartbeat > 0 && now >= heartbeat && (now - heartbeat) <= 8;
        status[@"daemonProcess"] = processName;
        status[@"daemonLoaded"] = @(heartbeatCurrent);
        status[@"heartbeatTimestamp"] = @(heartbeat);
        status[@"heartbeatAgeSeconds"] = heartbeat > 0 && now >= heartbeat ? @(now - heartbeat) : @(-1);
        if (heartbeatCurrent && ![status[@"runtimeVersion"] isEqualToString:VCamRuntimeVersion]) {
            status[@"runtimeVersion"] = VCamRuntimeVersion;
            status[@"daemonPID"] = @0; // heartbeat proves the injected runtime is alive; PID may be sandbox-hidden.
        }
        if ([processName isEqualToString:@"mediaserverd"]) {
            uint64_t counter = 0;
            if (VCamTryReadRuntimeCounter(@"cameraEmitCallbackCount", &counter)) {
                status[@"cameraEmitCallbackCount"] = @(counter);
            }
            if (VCamTryReadRuntimeCounter(@"cameraHookFrameCount", &counter)) {
                status[@"cameraHookFrameCount"] = @(counter);
            }
            if (VCamTryReadRuntimeCounter(@"cameraLocalPreviewSinkCount", &counter)) {
                status[@"cameraLocalPreviewSinkCount"] = @(counter);
            }
            if (VCamTryReadRuntimeCounter(@"cameraRemotePreviewSinkCount", &counter)) {
                status[@"cameraRemotePreviewSinkCount"] = @(counter);
            }
            if (VCamTryReadRuntimeCounter(@"cameraStillPhotoSinkCount", &counter)) {
                status[@"cameraStillPhotoSinkCount"] = @(counter);
            }
            if (VCamTryReadRuntimeCounter(@"replacementRenderCount", &counter)) {
                status[@"replacementRenderCount"] = @(counter);
            }
            if (VCamTryReadRuntimeCounter(@"renderSkipReason", &counter)) {
                NSString *skipReason = VCamRenderSkipReasonForCode(counter);
                if (skipReason) status[@"renderSkipReason"] = skipReason;
                else [status removeObjectForKey:@"renderSkipReason"];
            }
        }
        daemonStatuses[processName] = [status copy];

        NSDate *loadedAt = [status[@"daemonLoadedAt"] isKindOfClass:[NSDate class]] ? status[@"daemonLoadedAt"] : nil;
        if (!newestStatus || (loadedAt && (!newestDate || [loadedAt compare:newestDate] == NSOrderedDescending))) {
            newestStatus = status;
            newestDate = loadedAt;
        }
    }

    NSMutableDictionary *combined = [newestStatus mutableCopy] ?: [NSMutableDictionary dictionary];
    combined[@"daemonStatuses"] = [daemonStatuses copy];
    return [combined copy];
}

void VCamSetRuntimeStatus(NSString *key, id value) {
    if (key.length == 0) return;
    NSString *processName = VCamCurrentDaemonName();
    NSString *path = VCamRuntimeStatusFilePathForProcess(processName);
    @synchronized (processName) {
        NSMutableDictionary *status = [VCamReadRuntimeStatusForProcess(processName) mutableCopy];
        if (!status) status = [NSMutableDictionary dictionary];
        status[@"daemonProcess"] = processName;
        id oldValue = status[key];

        // Publish notify-backed counters/reason before the plist equality
        // fast-path. The plist can be stale or absent across RootHide views;
        // returning early here previously left a stale "media-not-ready"
        // reason in the shared notify state even after the render path cleared it.
        if ([key isEqualToString:@"cameraEmitCallbackCount"] ||
            [key isEqualToString:@"cameraHookFrameCount"] ||
            [key isEqualToString:@"cameraLocalPreviewSinkCount"] ||
            [key isEqualToString:@"cameraRemotePreviewSinkCount"] ||
            [key isEqualToString:@"cameraStillPhotoSinkCount"] ||
            [key isEqualToString:@"replacementRenderCount"]) {
            VCamPublishRuntimeCounter(key, value ? [value unsignedLongLongValue] : 0);
        } else if ([key isEqualToString:@"renderSkipReason"]) {
            VCamPublishRuntimeCounter(key, value ? VCamRenderSkipCode([value description]) : 0);
        }

        if (value && [oldValue isEqual:value]) return;
        if (!value && !oldValue) return;
        if (value) status[key] = value;
        else [status removeObjectForKey:key];

        if (!VCamEnsureRuntimeStatusDirectory()) return;
        BOOL didWrite = [status writeToFile:path atomically:YES];
        if (didWrite) chmod(path.fileSystemRepresentation, 0644);
        else NSLog(@"[VCam] failed to write runtime status %@", path);
    }
}

void VCamResetRuntimeStatus(void) {
    NSString *processName = VCamCurrentDaemonName();
    NSDictionary *initial = @{
        @"runtimeVersion": VCamRuntimeVersion,
        @"daemonLoaded": @YES,
        @"daemonLoadedAt": [NSDate date],
        @"daemonProcess": processName,
        @"daemonPID": @([[NSProcessInfo processInfo] processIdentifier]),
        @"hookState": @"searching",
        @"cameraFramesSeen": @NO,
        @"mediaState": @"not-checked",
        @"replacementRendered": @NO
    };
    NSString *path = VCamRuntimeStatusFilePathForProcess(processName);
    @synchronized (processName) {
        if (VCamEnsureRuntimeStatusDirectory()) {
            BOOL didWrite = [initial writeToFile:path atomically:YES];
            if (didWrite) chmod(path.fileSystemRepresentation, 0644);
            else NSLog(@"[VCam] failed to reset runtime status %@", path);
        }
    }

    // Publish immediately, then refresh every 2 seconds. A stale state expires
    // after 8 seconds in SpringBoard, so a crashed/restarted daemon is detected.
    VCamPublishHeartbeatForProcess(processName);
    if ([processName isEqualToString:@"mediaserverd"]) {
        VCamPublishRuntimeCounter(@"cameraEmitCallbackCount", 0);
        VCamPublishRuntimeCounter(@"cameraHookFrameCount", 0);
        VCamPublishRuntimeCounter(@"cameraLocalPreviewSinkCount", 0);
        VCamPublishRuntimeCounter(@"cameraRemotePreviewSinkCount", 0);
        VCamPublishRuntimeCounter(@"cameraStillPhotoSinkCount", 0);
        VCamPublishRuntimeCounter(@"replacementRenderCount", 0);
        VCamPublishRuntimeCounter(@"renderSkipReason", 0);
    }
    static dispatch_source_t heartbeatTimer;
    static dispatch_once_t timerOnce;
    dispatch_once(&timerOnce, ^{
        heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(heartbeatTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC,
                                  250 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(heartbeatTimer, ^{
            VCamPublishHeartbeatForProcess(processName);
        });
        dispatch_resume(heartbeatTimer);
    });
}

NSString *VCamMediaDirectory(void) {
    // Keep replacement files in the same shared temporary area that worked
    // with the original mediaserverd implementation (/tmp/test.png).
    return @"/var/tmp/VCamMedia";
}
