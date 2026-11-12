// System-wide "now playing" for LiteNotch.
//
// Since macOS 15.4 the private MediaRemote framework only answers processes
// with an Apple entitlement. /usr/bin/perl is such a process, so the app runs
//
//     /usr/bin/perl -MDynaLoader -e '<loader>' libnowplaying.dylib stream
//
// and this library does the work inside perl. It is LiteNotch's own code; the
// loading trick is the one used by the open-source mediaremote-adapter.
//
//   stream   one JSON object per line on stdout whenever playback changes;
//            exits when the parent process goes away
//   send N   send transport command N (0 play, 1 pause, 2 toggle, 4 next,
//            5 previous)
//
// Artwork is written to $LN_NP_ARTWORK_DIR (one file, replaced on change) and
// only its path is reported, so the JSON stays small.

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <libproc.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPidFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendFn)(unsigned int, id);

static void *mr(void) {
    static void *handle;
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    }
    return handle;
}

static void *sym(const char *name) {
    void *h = mr();
    return h ? dlsym(h, name) : NULL;
}

static NSString *artworkDir;
static NSString *lastArtworkPath;
static NSString *lastLine;

// "Google Chrome" for /Applications/Google Chrome.app/Contents/Frameworks/.../Helper.
static NSString *bundleName(int pid) {
    char buffer[PROC_PIDPATHINFO_MAXSIZE];
    if (pid <= 0 || proc_pidpath(pid, buffer, sizeof(buffer)) <= 0) return nil;
    for (NSString *part in @(buffer).pathComponents) {
        if ([part hasSuffix:@".app"]) return [part stringByDeletingPathExtension];
    }
    return nil;
}

// Safari plays media in a system service process that lives outside
// Safari.app; the process responsible for it is Safari itself.
static NSString *appName(int pid) {
    NSString *name = bundleName(pid);
    if (name) return name;
    pid_t (*responsible)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    return responsible ? bundleName(responsible(pid)) : nil;
}

static NSString *storeArtwork(NSData *data) {
    if (!artworkDir || data.length == 0 || data.length > 8 * 1024 * 1024) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *name = [NSMutableString stringWithString:@"art-"];
    for (int i = 0; i < 8; i++) [name appendFormat:@"%02x", digest[i]];
    NSString *path = [artworkDir stringByAppendingPathComponent:name];
    if ([path isEqualToString:lastArtworkPath]) return path;
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) return nil;
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
    if (lastArtworkPath) [[NSFileManager defaultManager] removeItemAtPath:lastArtworkPath error:nil];
    lastArtworkPath = path;
    return path;
}

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (!json) return;
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if ([line isEqualToString:lastLine]) return;
    lastLine = line;
    if (printf("%s\n", line.UTF8String) < 0 || fflush(stdout) != 0) exit(0);
}

static void refresh(void) {
    GetInfoFn getInfo = sym("MRMediaRemoteGetNowPlayingInfo");
    GetPlayingFn getPlaying = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetPidFn getPid = sym("MRMediaRemoteGetNowPlayingApplicationPID");
    if (!getInfo || !getPlaying || !getPid) return;
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        getPlaying(q, ^(Boolean playing) {
            getPid(q, ^(int pid) {
                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                if (![title isKindOfClass:NSString.class] || title.length == 0) {
                    emit(@{@"stopped": @YES});
                    return;
                }
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"title"] = title;
                id v;
                if ([(v = info[@"kMRMediaRemoteNowPlayingInfoArtist"]) isKindOfClass:NSString.class]) out[@"artist"] = v;
                if ([(v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) isKindOfClass:NSString.class]) out[@"album"] = v;
                if ([(v = info[@"kMRMediaRemoteNowPlayingInfoDuration"]) isKindOfClass:NSNumber.class])
                    out[@"duration_ms"] = @((long long)([v doubleValue] * 1000));
                if ([(v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]) isKindOfClass:NSNumber.class])
                    out[@"elapsed_ms"] = @((long long)([v doubleValue] * 1000));
                if ([(v = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"]) isKindOfClass:NSDate.class])
                    out[@"timestamp_ms"] = @((long long)([(NSDate *)v timeIntervalSince1970] * 1000));
                out[@"playing"] = @((BOOL)playing);
                if (pid > 0) {
                    NSString *app = appName(pid);
                    if (app) out[@"app"] = app;
                }
                if ([(v = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"]) isKindOfClass:NSData.class]) {
                    NSString *path = storeArtwork(v);
                    if (path) out[@"artwork_path"] = path;
                }
                emit(out);
            });
        });
    });
}

static void watchParent(void) {
    pid_t parent = getppid();
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, parent, DISPATCH_PROC_EXIT,
                                                      dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{ exit(0); });
    dispatch_resume(source);
    // Kept alive for the life of the process.
    (void)(__bridge_retained void *)source;
    if (getppid() != parent) exit(0);
}

__attribute__((visibility("default"))) void ln_np_stream(void) {
    @autoreleasepool {
        const char *dir = getenv("LN_NP_ARTWORK_DIR");
        if (dir && dir[0]) artworkDir = @(dir);
        RegisterFn reg = sym("MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!reg) {
            fprintf(stderr, "MediaRemote is not available\n");
            exit(2);
        }
        signal(SIGPIPE, SIG_DFL);
        watchParent();
        reg(dispatch_get_main_queue());
        for (NSString *name in @[
                 @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
             ]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(NSNotification *note) { refresh(); }];
        }
        refresh();
        CFRunLoopRun();
    }
}

__attribute__((visibility("default"))) void ln_np_send(void) {
    @autoreleasepool {
        const char *raw = getenv("LN_NP_COMMAND");
        SendFn send = sym("MRMediaRemoteSendCommand");
        if (!raw || !send) exit(2);
        int command = atoi(raw);
        if (command < 0 || command > 5) exit(2);
        send((unsigned int)command, nil);
        // The command is delivered asynchronously.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        exit(0);
    }
}
