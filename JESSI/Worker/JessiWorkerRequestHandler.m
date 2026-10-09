#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <pthread.h>
#import <sys/resource.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>

#import "../JessiCore/JessiPaths.h"
#import "../JessiCore/fishhook.h"
#import "../SwiftUI/JessiJITCheck.h"

int jessi_server_main(int argc, char *argv[]);
int jessi_tool_main(int argc, char *argv[]);

#pragma mark - Host channel

static int g_channelFD = -1;
static pthread_mutex_t g_channelLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *g_pendingCommands;
static NSCondition *g_commandsChanged;

static void worker_send(NSDictionary *event) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];

    pthread_mutex_lock(&g_channelLock);
    if (g_channelFD >= 0) {
        const uint8_t *bytes = line.bytes;
        size_t left = line.length;
        while (left > 0) {
            ssize_t n = send(g_channelFD, bytes, left, 0);
            if (n <= 0) break;
            bytes += n;
            left -= (size_t)n;
        }
    }
    pthread_mutex_unlock(&g_channelLock);
}

static void worker_log(NSString *message) {
    NSLog(@"[JESSI worker] %@", message);
    worker_send(@{@"event": @"log", @"message": message ?: @""});
}

static BOOL worker_connect(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NO;
    }
    g_channelFD = fd;
    return YES;
}

static void worker_close_listening_sockets(int keepPort);
static volatile int g_releasePortsOnHostClose = -1;

static void *worker_read_commands(void *unused) {
    NSMutableData *buffer = [NSMutableData data];
    uint8_t chunk[4096];
    while (1) {
        ssize_t n = recv(g_channelFD, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buffer appendBytes:chunk length:(NSUInteger)n];
        while (1) {
            const uint8_t *bytes = buffer.bytes;
            const uint8_t *newline = memchr(bytes, '\n', buffer.length);
            if (!newline) break;
            NSUInteger length = (NSUInteger)(newline - bytes);
            NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, length)];
            [buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
            NSString *name = [command isKindOfClass:[NSDictionary class]] ? command[@"cmd"] : nil;
            if (![name isKindOfClass:[NSString class]]) continue;
            [g_commandsChanged lock];
            NSMutableArray *queue = g_pendingCommands[name] ?: (g_pendingCommands[name] = [NSMutableArray array]);
            [queue addObject:command];
            [g_commandsChanged broadcast];
            [g_commandsChanged unlock];
        }
    }
    if (g_releasePortsOnHostClose >= 0) worker_close_listening_sockets(g_releasePortsOnHostClose);
    NSLog(@"[JESSI worker] host channel closed");
    [g_commandsChanged lock];
    NSMutableArray *queue = g_pendingCommands[@"host-closed"] ?: (g_pendingCommands[@"host-closed"] = [NSMutableArray array]);
    [queue addObject:@{@"cmd": @"host-closed"}];
    [g_commandsChanged broadcast];
    [g_commandsChanged unlock];
    return NULL;
}

static NSDictionary *worker_wait_for_command(NSArray<NSString *> *names, NSTimeInterval timeout) {
    NSDate *deadline = timeout > 0 ? [NSDate dateWithTimeIntervalSinceNow:timeout] : [NSDate distantFuture];
    [g_commandsChanged lock];
    NSDictionary *found = nil;
    while (!found) {
        for (NSString *name in names) {
            NSMutableArray *queue = g_pendingCommands[name];
            if (queue.count) {
                found = queue.firstObject;
                [queue removeObjectAtIndex:0];
                break;
            }
        }
        if (found) break;
        if (![g_commandsChanged waitUntilDate:deadline]) break;
    }
    [g_commandsChanged unlock];
    return found;
}

#pragma mark - Exit reporting

static void (*orig_exit)(int);
static void (*orig__exit)(int);
static volatile int g_exitReported = 0;

static void worker_report_exit(int code) {
    if (__sync_lock_test_and_set(&g_exitReported, 1)) return;
    worker_send(@{@"event": @"exit", @"code": @(code)});
}

static void worker_exit(int code) {
    worker_report_exit(code);
    orig_exit(code);
}

static void worker__exit(int code) {
    worker_report_exit(code);
    orig__exit(code);
}

static void worker_install_exit_hooks(void) {
    struct rebinding hooks[] = {
        {"exit", (void *)worker_exit, (void **)&orig_exit},
        {"_exit", (void *)worker__exit, (void **)&orig__exit},
    };
    rebind_symbols(hooks, 2);
    if (!orig_exit) orig_exit = exit;
    if (!orig__exit) orig__exit = _exit;
}

static void worker_finish(int code) {
    worker_report_exit(code);
    fflush(stdout);
    fflush(stderr);
    orig_exit ? orig_exit(code) : exit(code);
}

#pragma mark - Background

static void worker_mark_open_files_suspendable(void) {
    int maxFD = getdtablesize();
    for (int fd = 0; fd < maxFD; fd++) {
        struct stat st;
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        char path[PATH_MAX];
        if (fcntl(fd, F_GETPATH, path) != 0) continue;
        unsigned char value = 1;
        setxattr(path, "com.apple.runningboard.can-suspend-locked", &value, sizeof(value), 0, 0);
    }
}

static void worker_watch_host_background(void) {
    for (NSString *name in @[NSExtensionHostWillResignActiveNotification, NSExtensionHostDidEnterBackgroundNotification]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            worker_mark_open_files_suspendable();
        }];
    }
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ worker_mark_open_files_suspendable(); });
    dispatch_resume(timer);
}

static void worker_hold_background_activity(void) {
    [[NSProcessInfo processInfo] performExpiringActivityWithReason:@"JESSI server" usingBlock:^(BOOL expired) {
        if (expired) {
            worker_mark_open_files_suspendable();
            return;
        }
        dispatch_semaphore_wait(dispatch_semaphore_create(0), DISPATCH_TIME_FOREVER);
    }];
}

#pragma mark - Environment

static void worker_open_bookmarks(NSArray *bookmarks) {
    for (id data in bookmarks) {
        if (![data isKindOfClass:[NSData class]]) continue;
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:data options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
        if (!url) {
            worker_log([NSString stringWithFormat:@"Couldn't resolve a folder bookmark: %@", error.localizedDescription]);
            continue;
        }
        if (![url startAccessingSecurityScopedResource]) {
            worker_log([NSString stringWithFormat:@"No access granted to %@", url.path]);
        }
    }
}

static void worker_redirect_stdio(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    close(fd);
    setvbuf(stdout, NULL, _IOLBF, 0);
}

static BOOL worker_wait_for_jit(void) {
    if (jessi_check_jit_enabled()) return YES;
    worker_send(@{@"event": @"needs-jit"});
    NSDictionary *reply = worker_wait_for_command(@[@"jit-ready", @"jit-failed", @"host-closed"], 0);
    if (![reply[@"cmd"] isEqualToString:@"jit-ready"]) return NO;
    for (int i = 0; i < 50 && !jessi_check_jit_enabled(); i++) usleep(100000);
    return jessi_check_jit_enabled();
}

#pragma mark - Jobs

struct worker_proc_fdinfo {
    int32_t proc_fd;
    uint32_t proc_fdtype;
};
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);

#define WORKER_MAX_LISTENERS 32
static int g_listenFDs[WORKER_MAX_LISTENERS];
static int g_listenPorts[WORKER_MAX_LISTENERS];
static int g_listenCount;
static pthread_mutex_t g_listenLock = PTHREAD_MUTEX_INITIALIZER;

static BOOL worker_listening_port(int fd, int *port) {
    int type = 0;
    socklen_t typeLength = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeLength) != 0 || (type != SOCK_STREAM && type != SOCK_DGRAM)) return NO;
    struct sockaddr_storage addr;
    socklen_t addrLength = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &addrLength) != 0) return NO;
    if (addr.ss_family == AF_INET) *port = ntohs(((struct sockaddr_in *)&addr)->sin_port);
    else if (addr.ss_family == AF_INET6) *port = ntohs(((struct sockaddr_in6 *)&addr)->sin6_port);
    else return NO;
    if (*port == 0) return NO;
    struct sockaddr_storage peer;
    socklen_t peerLength = sizeof(peer);
    return getpeername(fd, (struct sockaddr *)&peer, &peerLength) != 0 && errno == ENOTCONN;
}

static void worker_scan_listening_sockets(void) {
    int foundFDs[WORKER_MAX_LISTENERS], foundPorts[WORKER_MAX_LISTENERS];
    int found = 0;
    int size = proc_pidinfo(getpid(), 1, 0, NULL, 0);
    struct worker_proc_fdinfo *fds = size > 0 ? malloc((size_t)size) : NULL;
    int count = fds ? proc_pidinfo(getpid(), 1, 0, fds, size) / (int)sizeof(struct worker_proc_fdinfo) : 0;
    if (count > 0) {
        for (int i = 0; i < count && found < WORKER_MAX_LISTENERS; i++) {
            if (fds[i].proc_fdtype != 2) continue;
            int port = 0;
            if (!worker_listening_port(fds[i].proc_fd, &port)) continue;
            foundFDs[found] = fds[i].proc_fd;
            foundPorts[found++] = port;
        }
    } else {
        struct rlimit limit = {0};
        getrlimit(RLIMIT_NOFILE, &limit);
        int maxFD = limit.rlim_cur > 0 && limit.rlim_cur < 16384 ? (int)limit.rlim_cur : 16384;
        for (int fd = 0; fd < maxFD && found < WORKER_MAX_LISTENERS; fd++) {
            int port = 0;
            if (!worker_listening_port(fd, &port)) continue;
            foundFDs[found] = fd;
            foundPorts[found++] = port;
        }
    }
    free(fds);
    pthread_mutex_lock(&g_listenLock);
    BOOL changed = found != g_listenCount;
    memcpy(g_listenFDs, foundFDs, sizeof(int) * (size_t)found);
    memcpy(g_listenPorts, foundPorts, sizeof(int) * (size_t)found);
    g_listenCount = found;
    pthread_mutex_unlock(&g_listenLock);
    if (changed) {
        NSMutableArray *ports = [NSMutableArray array];
        for (int i = 0; i < found; i++) [ports addObject:@(foundPorts[i])];
        NSLog(@"[JESSI worker] listening on %@", [ports componentsJoinedByString:@", "]);
    }
}

static void worker_watch_listening_sockets(void) {
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{ worker_scan_listening_sockets(); });
    dispatch_resume(timer);
}

static void worker_close_listening_sockets(int keepPort) {
    int closed = 0;
    int placeholder = open("/dev/null", O_RDONLY);
    pthread_mutex_lock(&g_listenLock);
    for (int i = 0; i < g_listenCount; i++) {
        if (g_listenFDs[i] < 0 || (keepPort > 0 && g_listenPorts[i] == keepPort)) continue;
        if ((placeholder >= 0 ? dup2(placeholder, g_listenFDs[i]) : close(g_listenFDs[i])) >= 0) closed++;
        g_listenFDs[i] = -1;
    }
    pthread_mutex_unlock(&g_listenLock);
    if (placeholder >= 0) close(placeholder);
    NSLog(@"[JESSI worker] closed %d listening socket(s)", closed);
}

static void worker_rcon_command(NSString *dir, int port, NSString *command, void (^afterSending)(void)) {
    NSString *password = [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@".jessi_rcon_password"] encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    int fd = password.length ? socket(AF_INET, SOCK_STREAM, 0) : -1;
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSLog(@"[JESSI worker] RCON: connect failed (errno %d)", errno);
        close(fd);
        fd = -1;
    }
    if (fd < 0) {
        if (afterSending) afterSending();
        return;
    }

    NSMutableData *packets = [NSMutableData data];
    void (^appendPacket)(int32_t, int32_t, NSString *) = ^(int32_t requestID, int32_t type, NSString *payload) {
        NSData *body = [payload dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        int32_t length = (int32_t)(10 + body.length);
        [packets appendBytes:&length length:4];
        [packets appendBytes:&requestID length:4];
        [packets appendBytes:&type length:4];
        [packets appendData:body];
        [packets appendBytes:"\0\0" length:2];
    };
    appendPacket(1, 3, password);
    appendPacket(2, 2, command);
    send(fd, packets.bytes, packets.length, 0);
    if (afterSending) afterSending();

    struct timeval timeout = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    uint8_t reply[4096];
    ssize_t received = recv(fd, reply, sizeof(reply), 0);
    NSLog(@"[JESSI worker] RCON %@: reply %zd bytes", command, received);
    close(fd);
}

static int worker_run_server(NSDictionary *job) {
    if (!worker_wait_for_jit()) return 240;
    NSString *dir = job[@"dir"];
    int rconPort = [job[@"rconPort"] intValue] ?: 25575;
    g_releasePortsOnHostClose = rconPort;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        worker_wait_for_command(@[@"host-closed"], 0);
        NSLog(@"[JESSI worker] JESSI went away; stopping the server");
        worker_rcon_command(dir, rconPort, @"stop", ^{
            worker_close_listening_sockets(0);
        });
    });
    char *argv[] = {
        strdup("--server"),
        strdup([job[@"jar"] fileSystemRepresentation]),
        strdup([job[@"javaVersion"] UTF8String] ?: "8"),
        strdup([job[@"dir"] fileSystemRepresentation]),
        NULL,
    };
    return jessi_server_main(4, argv);
}

static int worker_run_tool(NSDictionary *job) {
    if (!worker_wait_for_jit()) return 240;
    NSString *argsPath = job[@"argsPath"];
    char *argv[] = {
        strdup("--tool"),
        strdup([job[@"jar"] fileSystemRepresentation]),
        strdup([job[@"javaVersion"] UTF8String] ?: "8"),
        strdup([job[@"dir"] fileSystemRepresentation]),
        argsPath.length ? strdup(argsPath.fileSystemRepresentation) : NULL,
        NULL,
    };
    return jessi_tool_main(argsPath.length ? 5 : 4, argv);
}

typedef int (*PumpkinRunFn)(const char *dir);
typedef void (*PumpkinStopFn)(void);
typedef int (*PumpkinPromptFn)(const char *plugin, const char *version, const char *permissions);
typedef void (*PumpkinSetPromptFn)(PumpkinPromptFn callback);

static int worker_pumpkin_prompt(const char *plugin, const char *version, const char *permissions) {
    static int64_t nextID = 0;
    NSNumber *promptID = @(__sync_add_and_fetch(&nextID, 1));
    worker_send(@{
        @"event": @"pumpkin-prompt",
        @"id": promptID,
        @"plugin": plugin ? @(plugin) : @"",
        @"version": version ? @(version) : @"",
        @"permissions": permissions ? @(permissions) : @"",
    });
    while (1) {
        NSDictionary *reply = worker_wait_for_command(@[@"prompt-reply", @"host-closed"], 600);
        if (!reply || ![reply[@"cmd"] isEqualToString:@"prompt-reply"]) return -1;
        if ([reply[@"id"] isEqual:promptID]) return [reply[@"answer"] intValue];
    }
}

static int worker_run_pumpkin(NSDictionary *job) {
    if (!worker_wait_for_jit()) return 240;
    NSString *library = job[@"library"];
    NSString *dir = job[@"dir"];
    void *handle = jessi_dlopen_with_dyld_bypass(library.fileSystemRepresentation, RTLD_NOW);
    if (!handle) {
        const char *err = dlerror();
        worker_send(@{@"event": @"error", @"message": [NSString stringWithFormat:@"Failed to load %@: %s", library.lastPathComponent, err ?: "unknown error"]});
        return 254;
    }
    PumpkinRunFn run = (PumpkinRunFn)dlsym(handle, "pumpkin_run");
    PumpkinStopFn stop = (PumpkinStopFn)dlsym(handle, "pumpkin_stop");
    if (!run || !stop) {
        worker_send(@{@"event": @"error", @"message": [NSString stringWithFormat:@"%@ does not export pumpkin_run/pumpkin_stop.", library.lastPathComponent]});
        return 254;
    }
    PumpkinSetPromptFn setPrompt = (PumpkinSetPromptFn)dlsym(handle, "pumpkin_set_permission_prompt");
    if (setPrompt) setPrompt(worker_pumpkin_prompt);

    g_releasePortsOnHostClose = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *command = worker_wait_for_command(@[@"stop", @"host-closed"], 0);
        if ([command[@"cmd"] isEqual:@"host-closed"]) {
            NSLog(@"[JESSI worker] JESSI went away; stopping Pumpkin");
        }
        stop();
    });

    worker_redirect_stdio([dir stringByAppendingPathComponent:@"jessi-stdio.log"]);
    return run(dir.fileSystemRepresentation);
}

typedef struct {
    int32_t code;
    const char *lastAddress;
    const char *lastError;
} PlayitStatus;
typedef int32_t (*PlayitInitFn)(const char *config);
typedef int32_t (*PlayitStartFn)(void);
typedef int32_t (*PlayitStopFn)(void);
typedef void (*PlayitGetStatusFn)(PlayitStatus *status);
typedef void (*PlayitLogFn)(int32_t level, const char *message, void *context);
typedef void (*PlayitSetLogCallbackFn)(PlayitLogFn callback, void *context);

static void worker_playit_log(int32_t level, const char *message, void *context) {
    worker_send(@{@"event": @"playit-log", @"level": @(level), @"message": message ? (@(message) ?: @"") : @""});
}

static int worker_run_playit(NSDictionary *job) {
    if (!worker_wait_for_jit()) return 240;
    NSString *library = job[@"library"];
    void *handle = jessi_dlopen_with_dyld_bypass(library.fileSystemRepresentation, RTLD_NOW);
    if (!handle) {
        const char *err = dlerror();
        worker_send(@{@"event": @"error", @"message": [NSString stringWithFormat:@"Failed to load Playit library: %s", err ?: "unknown error"]});
        return 254;
    }
    PlayitInitFn playitInit = (PlayitInitFn)dlsym(handle, "playit_init");
    PlayitStartFn playitStart = (PlayitStartFn)dlsym(handle, "playit_start");
    PlayitStopFn playitStop = (PlayitStopFn)dlsym(handle, "playit_stop");
    PlayitGetStatusFn playitStatus = (PlayitGetStatusFn)dlsym(handle, "playit_get_status_out");
    PlayitSetLogCallbackFn playitSetLog = (PlayitSetLogCallbackFn)dlsym(handle, "playit_set_log_callback");
    if (!playitInit || !playitStart || !playitStop || !playitStatus || !playitSetLog) {
        worker_send(@{@"event": @"error", @"message": @"Failed to load Playit symbols"});
        return 254;
    }

    playitSetLog(worker_playit_log, NULL);
    NSData *config = [NSJSONSerialization dataWithJSONObject:@{@"secret_key": job[@"secret"] ?: @""} options:0 error:nil];
    NSString *configString = [[NSString alloc] initWithData:config encoding:NSUTF8StringEncoding];
    int32_t result = playitInit(configString.UTF8String);
    if (result != 0) {
        worker_send(@{@"event": @"error", @"message": [NSString stringWithFormat:@"Playit init failed (%d)", result]});
        return 1;
    }
    result = playitStart();
    if (result != 0) {
        worker_send(@{@"event": @"error", @"message": [NSString stringWithFormat:@"Playit start failed (%d)", result]});
        return 1;
    }
    worker_send(@{@"event": @"playit-started"});

    while (1) {
        PlayitStatus status = {0};
        playitStatus(&status);
        NSMutableDictionary *event = [@{@"event": @"playit-status", @"code": @(status.code)} mutableCopy];
        if (status.lastAddress) event[@"address"] = @(status.lastAddress) ?: @"";
        if (status.lastError) event[@"error"] = @(status.lastError) ?: @"";
        worker_send(event);

        NSDictionary *command = worker_wait_for_command(@[@"stop", @"host-closed"], 2);
        if (command) {
            result = playitStop();
            worker_send(@{@"event": @"playit-stopped", @"result": @(result)});
            return result == 0 ? 0 : 1;
        }
    }
}

void jessi_worker_run(NSDictionary *userInfo) {
    g_pendingCommands = [NSMutableDictionary dictionary];
    g_commandsChanged = [NSCondition new];

    uint16_t port = (uint16_t)[userInfo[@"port"] intValue];
    if (!worker_connect(port)) {
        NSLog(@"[JESSI worker] couldn't connect to JESSI on port %u", port);
        exit(250);
    }
    pthread_t reader;
    pthread_create(&reader, NULL, worker_read_commands, NULL);
    pthread_detach(reader);

    worker_install_exit_hooks();
    worker_watch_host_background();
    worker_watch_listening_sockets();
    worker_hold_background_activity();
    worker_send(@{@"event": @"hello", @"token": userInfo[@"token"] ?: @"", @"pid": @(getpid())});

    worker_open_bookmarks(userInfo[@"bookmarks"]);
    NSString *home = userInfo[@"home"];
    if (home.length) {
        [JessiPaths useHomeDirectory:home];
        setenv("HOME", home.fileSystemRepresentation, 1);
    }
    NSString *appBundle = userInfo[@"appBundle"];
    if (appBundle.length) [JessiPaths useAppBundlePath:appBundle];
    NSDictionary *settings = userInfo[@"settings"];
    if ([settings isKindOfClass:[NSDictionary class]]) {
        [[NSUserDefaults standardUserDefaults] setVolatileDomain:settings forName:NSArgumentDomain];
    }

    NSDictionary *job = userInfo[@"job"];
    NSString *type = job[@"type"];
    int code;
    if ([type isEqualToString:@"server"]) code = worker_run_server(job);
    else if ([type isEqualToString:@"tool"]) code = worker_run_tool(job);
    else if ([type isEqualToString:@"pumpkin"]) code = worker_run_pumpkin(job);
    else if ([type isEqualToString:@"playit"]) code = worker_run_playit(job);
    else {
        worker_send(@{@"event": @"error", @"message": [NSString stringWithFormat:@"Unknown worker job \"%@\"", type]});
        code = 2;
    }
    worker_finish(code);
}

@interface JESSIWorkerRequestHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation JESSIWorkerRequestHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSDictionary *userInfo = [(NSExtensionItem *)context.inputItems.firstObject userInfo] ?: @{};
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        jessi_worker_run(userInfo);
    }];
    thread.name = @"JESSI.worker";
    thread.stackSize = 16 << 20;
    [thread start];
}

@end
