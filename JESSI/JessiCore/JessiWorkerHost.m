#import "JessiWorkerHost.h"

#import "JessiPaths.h"
#import "../SwiftUI/JessiJITCheck.h"

#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <netinet/in.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString *const JessiWorkerPrincipalClass = @"JESSIWorkerRequestHandler";
static NSString *const JessiWorkerFrameworkName = @"JessiWorkerCore.framework";
static NSString *const JessiWorkerPayloadEntry = @"jessi_worker_payload_main";
static NSString *const JessiWorkerDisabledKey = @"jessi.worker.disabled";
static NSString *const JessiLiveWorkersKey = @"jessi.worker.live";

int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

@protocol JessiExtension <NSObject>
- (void)beginExtensionRequestWithInputItems:(NSArray *)inputItems completion:(void (^)(NSUUID *requestIdentifier))completion;
- (int)pidForRequestIdentifier:(NSUUID *)requestIdentifier;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID *)requestIdentifier;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *uuid, NSError *error))block;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *uuid, NSArray *items))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *uuid))block;
@optional
- (void)_kill:(int)signal;
@end

@protocol JessiExtensionFactory <NSObject>
+ (id<JessiExtension>)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
@end

static JessiWorkerJITStarter g_jitStarter;

void jessi_keep_extension_running_in_background(id extension) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:extension name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center removeObserver:extension name:UIApplicationWillResignActiveNotification object:nil];
}

@interface JessiWorkerHost ()
+ (void)rememberWorkerPID:(pid_t)pid;
+ (void)forgetWorkerPID:(pid_t)pid;
+ (nullable NSString *)workerExtensionIdentifier;
+ (nullable NSString *)liveProcessIdentifier;
+ (nullable NSString *)payloadPathForLiveProcess:(NSString *_Nullable *_Nullable)problem;
+ (NSArray<NSData *> *)containerBookmarks;
+ (NSDictionary *)settingsSnapshot;
@end

@interface JessiWorker ()
@property (nonatomic, readwrite) pid_t pid;
@property (nonatomic, readwrite, getter=isFinished) BOOL finished;
@property (nonatomic) BOOL needsJIT;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) void (^onLog)(NSString *);
@property (nonatomic, copy) void (^onEvent)(NSDictionary *);
@property (nonatomic, copy) void (^onExit)(int, NSString *);
@property (nonatomic, strong) id<JessiExtension> extension;
@property (nonatomic, strong) NSUUID *requestID;
@property (nonatomic, strong) NSNumber *exitCode;
@property (nonatomic) BOOL connected;
@property (nonatomic) int listenFD;
@property (nonatomic) int channelFD;
@end

@implementation JessiWorker {
    dispatch_queue_t _stateQueue;
    NSLock *_sendLock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.baconmania.jessi.worker-host", DISPATCH_QUEUE_SERIAL);
        _sendLock = [NSLock new];
        _listenFD = -1;
        _channelFD = -1;
    }
    return self;
}

- (void)setPid:(pid_t)pid {
    _pid = pid;
    if (pid > 0) [JessiWorkerHost rememberWorkerPID:pid];
}

- (void)send:(NSDictionary *)command {
    NSData *json = [NSJSONSerialization dataWithJSONObject:command options:0 error:nil];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    [_sendLock lock];
    int fd = self.channelFD;
    if (fd >= 0) {
        const uint8_t *bytes = line.bytes;
        size_t left = line.length;
        while (left > 0) {
            ssize_t n = send(fd, bytes, left, 0);
            if (n <= 0) break;
            bytes += n;
            left -= (size_t)n;
        }
    }
    [_sendLock unlock];
}

- (void)terminate {
    id<JessiExtension> extension = self.extension;
    NSUUID *requestID = self.requestID;
    if (extension && requestID) {
        [extension cancelExtensionRequestWithIdentifier:requestID];
    }
    if ([extension respondsToSelector:@selector(_kill:)]) {
        [extension _kill:SIGKILL];
    }
    if (self.pid > 0) kill(self.pid, SIGKILL);
}

- (void)log:(NSString *)line {
    void (^onLog)(NSString *) = self.onLog;
    if (!onLog || !line) return;
    if (![line hasSuffix:@"\n"]) line = [line stringByAppendingString:@"\n"];
    dispatch_async(dispatch_get_main_queue(), ^{ onLog(line); });
}

- (void)finishWithCode:(int)code problem:(NSString *)problem {
    __block BOOL alreadyFinished = NO;
    dispatch_sync(_stateQueue, ^{
        alreadyFinished = self.finished;
        self.finished = YES;
    });
    if (alreadyFinished) return;

    if (self.pid > 0) [JessiWorkerHost forgetWorkerPID:self.pid];
    if (self.listenFD >= 0) { close(self.listenFD); self.listenFD = -1; }
    void (^onExit)(int, NSString *) = self.onExit;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (onExit) onExit(code, problem);
    });
}

#pragma mark Launch

- (void)startWithJob:(NSDictionary *)job {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t addrLen = sizeof(addr);
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 1) != 0 ||
        getsockname(fd, (struct sockaddr *)&addr, &addrLen) != 0) {
        if (fd >= 0) close(fd);
        [self finishWithCode:255 problem:[NSString stringWithFormat:@"Couldn't open a channel to the server process (errno %d).", errno]];
        return;
    }
    self.listenFD = fd;
    uint16_t port = ntohs(addr.sin_port);

    BOOL viaLiveProcess = [JessiWorkerHost liveProcessIdentifier] != nil;
    NSString *identifier = viaLiveProcess ? [JessiWorkerHost liveProcessIdentifier] : [JessiWorkerHost workerExtensionIdentifier];
    NSString *payloadPath = nil;
    if (viaLiveProcess) {
        NSString *problem = nil;
        payloadPath = [JessiWorkerHost payloadPathForLiveProcess:&problem];
        if (!payloadPath) {
            [self finishWithCode:255 problem:problem];
            return;
        }
    }
    Class extensionClass = NSClassFromString(@"NSExtension");
    NSError *error = nil;
    id<JessiExtension> extension = nil;
    if (identifier && extensionClass) {
        extension = [(Class<JessiExtensionFactory>)extensionClass extensionWithIdentifier:identifier error:&error];
    }
    if (!extension) {
        NSString *detail = error ? [NSString stringWithFormat:@" (%@)", error.localizedDescription] : @"";
        [self finishWithCode:255 problem:viaLiveProcess
            ? [NSString stringWithFormat:@"LiveContainer's LiveProcess extension couldn't be loaded%@. Reinstall LiveContainer and keep its extensions.", detail]
            : [NSString stringWithFormat:@"The server worker extension couldn't be loaded%@. Make sure your signing tool keeps app extensions.", detail]];
        return;
    }
    self.extension = extension;

    __weak typeof(self) weakSelf = self;
    void (^processEnded)(NSString *) = ^(NSString *reason) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.connected) [strongSelf finishWithCode:252 problem:reason];
    };
    [extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        processEnded(@"The server process stopped before it connected to JESSI.");
    }];
    [extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *cancelError) {
        processEnded([NSString stringWithFormat:@"The server process was cancelled%@", cancelError ? [NSString stringWithFormat:@": %@", cancelError.localizedDescription] : @"."]);
    }];
    [extension setRequestCompletionBlock:^(NSUUID *uuid, NSArray *items) {
        processEnded(@"The server process exited before it connected to JESSI.");
    }];

    NSMutableDictionary *userInfo = [@{
        @"port": @(port),
        @"token": self.token,
        @"job": job,
        @"home": [JessiPaths homeDirectory],
        @"bookmarks": [JessiWorkerHost containerBookmarks],
        @"settings": [JessiWorkerHost settingsSnapshot],
    } mutableCopy];
    if (viaLiveProcess) {
        userInfo[@"customPayloadDylib"] = payloadPath;
        userInfo[@"customPayloadEntry"] = JessiWorkerPayloadEntry;
        userInfo[@"appBundle"] = [JessiPaths appBundle].bundlePath;
    }
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = userInfo;

    [NSThread detachNewThreadWithBlock:^{
        [weakSelf acceptAndServe];
    }];

    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *requestIdentifier) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.requestID = requestIdentifier;
        if (!requestIdentifier) {
            [strongSelf finishWithCode:255 problem:@"iOS refused to start the server process."];
            return;
        }
        int pid = [extension pidForRequestIdentifier:requestIdentifier];
        if (pid > 0 && strongSelf.pid <= 0) strongSelf.pid = pid;
        dispatch_async(dispatch_get_main_queue(), ^{ jessi_keep_extension_running_in_background(extension); });
    }];
    jessi_keep_extension_running_in_background(extension);
}

- (void)acceptAndServe {
    int listenFD = self.listenFD;
    if (listenFD < 0) return;

    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(listenFD, &fds);
    struct timeval timeout = { .tv_sec = 30, .tv_usec = 0 };
    if (select(listenFD + 1, &fds, NULL, NULL, &timeout) <= 0) {
        [self terminate];
        [self finishWithCode:254 problem:@"The server process didn't start within 30 seconds."];
        return;
    }
    int fd = accept(listenFD, NULL, NULL);
    close(listenFD);
    self.listenFD = -1;
    if (fd < 0) {
        [self finishWithCode:254 problem:@"The server process couldn't connect to JESSI."];
        return;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    self.channelFD = fd;
    self.connected = YES;

    NSMutableData *buffer = [NSMutableData data];
    uint8_t chunk[8192];
    BOOL greeted = NO;
    while (1) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buffer appendBytes:chunk length:(NSUInteger)n];
        while (1) {
            const uint8_t *bytes = buffer.bytes;
            const uint8_t *newline = memchr(bytes, '\n', buffer.length);
            if (!newline) break;
            NSUInteger length = (NSUInteger)(newline - bytes);
            NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, length)];
            [buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
            NSDictionary *event = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
            if (![event isKindOfClass:[NSDictionary class]]) continue;

            if (!greeted) {
                if (![event[@"event"] isEqual:@"hello"] || ![event[@"token"] isEqual:self.token]) {
                    close(fd);
                    self.channelFD = -1;
                    [self terminate];
                    [self finishWithCode:254 problem:@"An unexpected process connected to JESSI's server channel."];
                    return;
                }
                greeted = YES;
                self.pid = [event[@"pid"] intValue];
                continue;
            }
            [self handleEvent:event];
        }
    }

    [_sendLock lock];
    close(fd);
    self.channelFD = -1;
    [_sendLock unlock];

    NSNumber *exitCode = self.exitCode;
    if (exitCode) {
        [self finishWithCode:exitCode.intValue problem:nil];
    } else {
        [self finishWithCode:252 problem:@"The server process ended unexpectedly. iOS may have closed it for using too much memory (try lowering the RAM limit in Settings) or while JESSI was in the background."];
    }
}

- (void)handleEvent:(NSDictionary *)event {
    NSString *name = event[@"event"];
    if ([name isEqualToString:@"log"]) {
        [self log:event[@"message"]];
    } else if ([name isEqualToString:@"exit"]) {
        self.exitCode = event[@"code"];
    } else if ([name isEqualToString:@"needs-jit"]) {
        [self enableJIT];
    } else {
        void (^onEvent)(NSDictionary *) = self.onEvent;
        if (onEvent) dispatch_async(dispatch_get_main_queue(), ^{ onEvent(event); });
    }
}

- (void)enableJIT {
    JessiWorkerJITStarter starter = g_jitStarter;
    if (!self.needsJIT || !starter) {
        [self send:@{@"cmd": @"jit-failed"}];
        return;
    }
    pid_t pid = self.pid;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf log:@"Enabling JIT for the server process…\n"];
        starter(pid, ^(NSString *line) {
            NSLog(@"[JESSI] [JIT pid %d] %@", pid, line);
        }, ^(NSString *error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.finished) return;
            if (!error) {
                [strongSelf log:@"JIT enabled.\n"];
                [strongSelf send:@{@"cmd": @"jit-ready"}];
                return;
            }
            [strongSelf send:@{@"cmd": @"jit-failed"}];
            [strongSelf terminate];
            [strongSelf finishWithCode:240 problem:[NSString stringWithFormat:@"JIT couldn't be enabled for the server process:\n%@", error]];
        });
    });
}

@end

@implementation JessiWorkerHost

+ (JessiWorkerJITStarter)jitStarter { return g_jitStarter; }
+ (void)setJitStarter:(JessiWorkerJITStarter)jitStarter { g_jitStarter = [jitStarter copy]; }

+ (NSString *)workerExtensionIdentifier {
    static NSString *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *plugIns = [NSBundle mainBundle].builtInPlugInsURL;
        for (NSURL *appex in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:plugIns includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![appex.pathExtension isEqualToString:@"appex"]) continue;
            NSBundle *bundle = [NSBundle bundleWithURL:appex];
            NSDictionary *extension = bundle.infoDictionary[@"NSExtension"];
            if ([extension[@"NSExtensionPrincipalClass"] isEqual:JessiWorkerPrincipalClass]) {
                identifier = bundle.bundleIdentifier;
                break;
            }
        }
    });
    return identifier;
}

#pragma mark Orphaned workers

+ (void)rememberWorkerPID:(pid_t)pid {
    @synchronized (self) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableArray *live = [[defaults arrayForKey:JessiLiveWorkersKey] ?: @[] mutableCopy];
        NSDictionary *entry = @{@"pid": @(pid), @"host": @(getpid())};
        if (![live containsObject:entry]) [live addObject:entry];
        [defaults setObject:live forKey:JessiLiveWorkersKey];
    }
}

+ (void)forgetWorkerPID:(pid_t)pid {
    @synchronized (self) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSArray *live = [defaults arrayForKey:JessiLiveWorkersKey] ?: @[];
        NSPredicate *others = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) {
            return [entry[@"pid"] intValue] != pid;
        }];
        [defaults setObject:[live filteredArrayUsingPredicate:others] forKey:JessiLiveWorkersKey];
    }
}

static BOOL jessi_pid_is_worker_process(pid_t pid) {
    char path[4096] = {0};
    NSString *name = nil;
    if (proc_pidpath(pid, path, sizeof(path)) > 0) {
        name = @(path).lastPathComponent;
    } else {
        struct kinfo_proc info;
        size_t size = sizeof(info);
        int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
        if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return NO;
        name = @(info.kp_proc.p_comm);
    }
    return [name isEqualToString:@"JESSIWorker"] || [name isEqualToString:@"LiveProcess"];
}

+ (void)reapOrphanedWorkers {
    NSArray *live;
    @synchronized (self) {
        live = [[NSUserDefaults standardUserDefaults] arrayForKey:JessiLiveWorkersKey] ?: @[];
    }
    for (NSDictionary *entry in live) {
        pid_t pid = [entry[@"pid"] intValue];
        if ([entry[@"host"] intValue] == getpid() || pid <= 1) continue;
        if (kill(pid, 0) != 0) {
            NSLog(@"[JESSI] Server process %d from a previous launch: %s", pid, errno == ESRCH ? "already gone" : strerror(errno));
        } else if (!jessi_pid_is_worker_process(pid)) {
            NSLog(@"[JESSI] Server process %d from a previous launch: pid now belongs to something else", pid);
        } else {
            int result = kill(pid, SIGKILL);
            NSLog(@"[JESSI] Killing server process %d left over from a previous launch: %s", pid, result == 0 ? "done" : strerror(errno));
        }
        [self forgetWorkerPID:pid];
    }
}

+ (BOOL)workerExtensionAvailable {
    return [self workerExtensionIdentifier] != nil;
}

#pragma mark LiveContainer

static BOOL g_inLiveContainer(void) {
    static BOOL inLiveContainer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inLiveContainer = jessi_is_livecontainer_installed(); });
    return inLiveContainer;
}

static NSString *liveContainerBundlePath(void) {
    const char *executable = _dyld_get_image_name(0);
    if (!executable) return nil;
    NSString *bundle = @(executable).stringByDeletingLastPathComponent;
    return [bundle.pathExtension isEqualToString:@"app"] ? bundle : nil;
}

+ (NSString *)liveProcessIdentifier {
    static NSString *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!g_inLiveContainer()) return;
        NSString *appex = [liveContainerBundlePath() stringByAppendingPathComponent:@"PlugIns/LiveProcess.appex"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appex stringByAppendingPathComponent:@"Info.plist"]];
        NSString *bundleID = info[@"CFBundleIdentifier"];
        NSString *executable = info[@"CFBundleExecutable"];
        if (!bundleID.length || !executable.length) {
            NSLog(@"[JESSI] LiveContainer's LiveProcess extension wasn't found at %@", appex);
            return;
        }
        NSData *binary = [NSData dataWithContentsOfFile:[appex stringByAppendingPathComponent:executable] options:NSDataReadingMappedIfSafe error:nil];
        NSData *marker = [@"customPayloadDylib" dataUsingEncoding:NSUTF8StringEncoding];
        if (!binary || [binary rangeOfData:marker options:0 range:NSMakeRange(0, binary.length)].location == NSNotFound) {
            NSLog(@"[JESSI] This LiveContainer's LiveProcess can't run custom payloads (needs LiveContainer 3.8 or newer)");
            return;
        }
        identifier = bundleID;
    });
    return identifier;
}

+ (BOOL)runsJITInProcess {
    return [self liveProcessIdentifier] != nil;
}

+ (NSString *)payloadPathForLiveProcess:(NSString **)problem {
    NSString *source = [[JessiPaths appBundle].privateFrameworksPath stringByAppendingPathComponent:JessiWorkerFrameworkName];
    NSString *binary = [source stringByAppendingPathComponent:@"JessiWorkerCore"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attributes = [fm attributesOfItemAtPath:binary error:nil];
    if (!attributes) {
        if (problem) *problem = @"JessiWorkerCore.framework is missing from this copy of JESSI.";
        return nil;
    }

    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    NSURL *group = [sharedUtils respondsToSelector:@selector(appGroupPath)] ? [sharedUtils performSelector:@selector(appGroupPath)] : nil;
    if (![group isKindOfClass:[NSURL class]]) {
        if (problem) *problem = @"Couldn't find LiveContainer's app group, which the server process needs to load JESSI's code from. Make sure LiveContainer was installed with SideStore or AltStore's app group.";
        return nil;
    }
    if ([source hasPrefix:[group.path stringByAppendingString:@"/"]]) return binary;

    NSString *stamp = [NSString stringWithFormat:@"%llu-%.0f", [attributes fileSize], [[attributes fileModificationDate] timeIntervalSince1970]];
    NSString *root = [group.path stringByAppendingPathComponent:@"JESSI/WorkerPayload"];
    NSString *destination = [[root stringByAppendingPathComponent:stamp] stringByAppendingPathComponent:JessiWorkerFrameworkName];
    NSString *destinationBinary = [destination stringByAppendingPathComponent:@"JessiWorkerCore"];
    if ([fm fileExistsAtPath:destinationBinary]) return destinationBinary;

    for (NSString *old in [fm contentsOfDirectoryAtPath:root error:nil]) {
        [fm removeItemAtPath:[root stringByAppendingPathComponent:old] error:nil];
    }
    NSError *error = nil;
    if (![fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![fm copyItemAtPath:source toPath:destination error:&error]) {
        if (problem) *problem = [NSString stringWithFormat:@"Couldn't copy JESSI's server code to LiveContainer's app group: %@", error.localizedDescription];
        return nil;
    }
    return destinationBinary;
}

+ (BOOL)shouldUseWorkers {
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
    return NO;
#else
    if (jessi_is_running_on_macos()) return NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:JessiWorkerDisabledKey]) return NO;
    if (!g_jitStarter) return NO;
    if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){17, 4, 0}]) return NO;
    if (jessi_has_trollstore_privileges()) return NO;

    if (g_inLiveContainer()) {
        if (!self.liveProcessIdentifier) return NO;
    } else if (!self.workerExtensionAvailable) {
        return NO;
    }

    return [[NSFileManager defaultManager] fileExistsAtPath:[JessiPaths pairingFilePath]];
#endif
}

+ (NSArray<NSData *> *)containerBookmarks {
    NSString *home = [JessiPaths homeDirectory];
    NSMutableArray<NSData *> *bookmarks = [NSMutableArray array];
    NSMutableArray<NSString *> *paths = [@[[home stringByAppendingPathComponent:@"Documents"], [home stringByAppendingPathComponent:@"Library"]] mutableCopy];
    if (self.liveProcessIdentifier) [paths addObject:[JessiPaths appBundle].bundlePath];
    for (NSString *path in paths) {
        NSData *bookmark = [[NSURL fileURLWithPath:path isDirectory:YES] bookmarkDataWithOptions:(NSURLBookmarkCreationOptions)(1 << 11)
                                                                     includingResourceValuesForKeys:nil
                                                                                      relativeToURL:nil
                                                                                              error:nil];
        if (bookmark) [bookmarks addObject:bookmark];
    }
    return bookmarks;
}

+ (NSDictionary *)settingsSnapshot {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    [[[NSUserDefaults standardUserDefaults] dictionaryRepresentation] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (![key hasPrefix:@"jessi."]) return;
        if ([NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0]) settings[key] = value;
    }];
    return settings;
}

+ (JessiWorker *)launchJob:(NSDictionary *)job
                  needsJIT:(BOOL)needsJIT
                     onLog:(void (^)(NSString *))onLog
                   onEvent:(void (^)(NSDictionary *))onEvent
                    onExit:(void (^)(int, NSString *))onExit {
    JessiWorker *worker = [JessiWorker new];
    worker.needsJIT = needsJIT;
    worker.token = [NSUUID UUID].UUIDString;
    worker.onLog = onLog;
    worker.onEvent = onEvent;
    worker.onExit = onExit;
    [worker startWithJob:job];
    return worker;
}

@end

int jessi_worker_run_tool(int argc, char *argv[]) {
    if (argc < 4) return 2;
    NSMutableDictionary *job = [@{
        @"type": @"tool",
        @"jar": @(argv[1]),
        @"javaVersion": @(argv[2]),
        @"dir": @(argv[3]),
    } mutableCopy];
    if (argc > 4 && argv[4]) job[@"argsPath"] = @(argv[4]);

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int result = 0;
    __block JessiWorker *worker = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        worker = [JessiWorkerHost launchJob:job needsJIT:YES onLog:^(NSString *line) {
            NSLog(@"[JESSI] installer: %@", line);
        } onEvent:^(NSDictionary *event) {
            if ([event[@"event"] isEqual:@"error"]) NSLog(@"[JESSI] installer: %@", event[@"message"]);
        } onExit:^(int code, NSString *problem) {
            if (problem) NSLog(@"[JESSI] installer worker: %@", problem);
            result = code;
            dispatch_semaphore_signal(done);
        }];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    worker = nil;
    return result;
}
