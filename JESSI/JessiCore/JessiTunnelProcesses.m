#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <pthread.h>
#import <signal.h>
#import <stdio.h>
#import <unistd.h>

void *jessi_dlopen_with_dyld_bypass(const char *path, int flags);

static dispatch_source_t g_parentExitSource;
static dispatch_source_t g_terminateSource;

static void jessi_child_watch_parent(dispatch_block_t onExit) {
    pid_t parent = getppid();
    g_parentExitSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent, DISPATCH_PROC_EXIT, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(g_parentExitSource, onExit);
    dispatch_resume(g_parentExitSource);
    if (getppid() != parent) onExit();
}

static void *jessi_child_load(const char *path, const char *name) {
    void *handle = jessi_dlopen_with_dyld_bypass(path, RTLD_NOW);
    if (!handle) {
        const char *err = dlerror();
        fprintf(stderr, "Failed to load the %s library: %s\n", name, err ?: "unknown error");
    }
    return handle;
}

typedef int (*JessiCloudflaredRunFn)(int argc, char **argv);

typedef struct {
    JessiCloudflaredRunFn run;
    int argc;
    char **argv;
    int result;
} JessiCloudflaredCtx;

static void *jessi_cloudflared_thread(void *context) {
    JessiCloudflaredCtx *ctx = context;
    ctx->result = ctx->run(ctx->argc, ctx->argv);
    return NULL;
}

int jessi_cloudflared_main(int argc, char *argv[]) {
    if (argc < 2) return 254;
    void *handle = jessi_child_load(argv[1], "Cloudflare");
    if (!handle) return 254;
    JessiCloudflaredRunFn run = (JessiCloudflaredRunFn)dlsym(handle, "cloudflared_run");
    if (!run) {
        fprintf(stderr, "The Cloudflare library is missing cloudflared_run\n");
        return 254;
    }

    jessi_child_watch_parent(^{
        kill(getpid(), SIGTERM);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ _exit(0); });
    });

    JessiCloudflaredCtx ctx = { .run = run, .argc = argc - 2, .argv = argv + 2, .result = 0 };
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 << 20);
    pthread_t thread;
    if (pthread_create(&thread, &attr, jessi_cloudflared_thread, &ctx) != 0) {
        pthread_attr_destroy(&attr);
        return 253;
    }
    pthread_attr_destroy(&attr);
    pthread_join(thread, NULL);
    return ctx.result;
}

typedef struct {
    int32_t code;
    const char *lastAddress;
    const char *lastError;
} JessiPlayitStatus;
typedef int32_t (*JessiPlayitInitFn)(const char *config);
typedef int32_t (*JessiPlayitStartFn)(void);
typedef int32_t (*JessiPlayitStopFn)(void);
typedef void (*JessiPlayitGetStatusFn)(JessiPlayitStatus *status);
typedef void (*JessiPlayitLogFn)(int32_t level, const char *message, void *context);
typedef void (*JessiPlayitSetLogCallbackFn)(JessiPlayitLogFn callback, void *context);

static pthread_mutex_t g_playitLogLock = PTHREAD_MUTEX_INITIALIZER;

static void jessi_playit_log(int32_t level, const char *message, void *context) {
    pthread_mutex_lock(&g_playitLogLock);
    if (ftello(stdout) > (1 << 20)) {
        fflush(stdout);
        ftruncate(STDOUT_FILENO, 0);
        rewind(stdout);
    }
    fprintf(stdout, "%d\t%s\n", level, message ?: "");
    pthread_mutex_unlock(&g_playitLogLock);
}

static NSData *jessi_playit_status_json(JessiPlayitStatus status) {
    NSMutableDictionary *dict = [@{@"code": @(status.code)} mutableCopy];
    if (status.lastAddress) dict[@"address"] = @(status.lastAddress) ?: @"";
    if (status.lastError) dict[@"error"] = @(status.lastError) ?: @"";
    return [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
}

int jessi_playit_main(int argc, char *argv[]) {
    if (argc < 3) return 254;
    setvbuf(stdout, NULL, _IOLBF, 0);
    NSString *statusPath = @(argv[2]);
    NSData *secretData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSString *secret = [[[NSString alloc] initWithData:secretData encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (secret.length == 0) {
        fprintf(stderr, "Playit not linked\n");
        return 254;
    }

    void *handle = jessi_child_load(argv[1], "Playit");
    if (!handle) return 254;
    JessiPlayitInitFn playitInit = (JessiPlayitInitFn)dlsym(handle, "playit_init");
    JessiPlayitStartFn playitStart = (JessiPlayitStartFn)dlsym(handle, "playit_start");
    JessiPlayitStopFn playitStop = (JessiPlayitStopFn)dlsym(handle, "playit_stop");
    JessiPlayitGetStatusFn playitStatus = (JessiPlayitGetStatusFn)dlsym(handle, "playit_get_status_out");
    JessiPlayitSetLogCallbackFn playitSetLog = (JessiPlayitSetLogCallbackFn)dlsym(handle, "playit_set_log_callback");
    if (!playitInit || !playitStart || !playitStop || !playitStatus || !playitSetLog) {
        fprintf(stderr, "Failed to load Playit symbols\n");
        return 254;
    }

    dispatch_semaphore_t stopRequested = dispatch_semaphore_create(0);
    signal(SIGTERM, SIG_IGN);
    g_terminateSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(g_terminateSource, ^{ dispatch_semaphore_signal(stopRequested); });
    dispatch_resume(g_terminateSource);
    jessi_child_watch_parent(^{ dispatch_semaphore_signal(stopRequested); });

    playitSetLog(jessi_playit_log, NULL);
    NSData *config = [NSJSONSerialization dataWithJSONObject:@{@"secret_key": secret} options:0 error:nil];
    NSString *configString = [[NSString alloc] initWithData:config encoding:NSUTF8StringEncoding];
    int32_t result = playitInit(configString.UTF8String);
    if (result != 0) {
        fprintf(stderr, "Playit init failed (%d)\n", result);
        return 1;
    }
    result = playitStart();
    if (result != 0) {
        fprintf(stderr, "Playit start failed (%d)\n", result);
        return 1;
    }

    NSData *written = nil;
    while (1) {
        @autoreleasepool {
            JessiPlayitStatus status = {0};
            playitStatus(&status);
            NSData *json = jessi_playit_status_json(status);
            if (json && ![json isEqualToData:written]) {
                [json writeToFile:statusPath atomically:YES];
                written = json;
            }
        }
        if (dispatch_semaphore_wait(stopRequested, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0) break;
    }

    result = playitStop();
    [[NSFileManager defaultManager] removeItemAtPath:statusPath error:nil];
    if (result != 0) fprintf(stderr, "Playit stop failed (%d)\n", result);
    return result == 0 ? 0 : 1;
}
