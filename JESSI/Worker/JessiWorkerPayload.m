#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>

int jessi_server_main(int argc, char *argv[]);
int jessi_tool_main(int argc, char *argv[]);
void jessi_worker_run(NSDictionary *userInfo);

static const char *nonempty_env(const char *name) {
    const char *value = getenv(name);
    return (value && *value) ? value : NULL;
}

__attribute__((visibility("default")))
int main(int argc, char *argv[]) {
    if (!nonempty_env("JESSI_LAUNCHED_BY_JLI")) return 0;

    const char *mode = nonempty_env("JESSI_MODE");
    if (mode && strcmp(mode, "tool") == 0) {
        const char *jar = nonempty_env("JESSI_TOOL_JAR");
        const char *version = nonempty_env("JESSI_TOOL_JAVA_VERSION");
        const char *dir = nonempty_env("JESSI_TOOL_WORKDIR");
        const char *argsPath = nonempty_env("JESSI_TOOL_ARGS_PATH");
        if (!jar || !version || !dir) return 0;
        char *toolArgv[] = { "--tool", (char *)jar, (char *)version, (char *)dir, (char *)(argsPath ?: ""), NULL };
        return jessi_tool_main(argsPath ? 5 : 4, toolArgv);
    }

    const char *jar = nonempty_env("JESSI_SERVER_JAR");
    const char *version = nonempty_env("JESSI_SERVER_JAVA_VERSION");
    const char *dir = nonempty_env("JESSI_SERVER_WORKDIR");
    if (!jar || !version || !dir) return 0;
    char *serverArgv[] = { "--server", (char *)jar, (char *)version, (char *)dir, NULL };
    return jessi_server_main(4, serverArgv);
}

@interface NSObject (JessiLiveProcessHandler)
+ (NSDictionary *)retrievedAppInfo;
@end

__attribute__((visibility("default")))
int jessi_worker_payload_main(int argc, char *argv[], char *envp[], char *apple[]) {
    Class handler = NSClassFromString(@"LiveProcessHandler");
    NSDictionary *userInfo = [handler respondsToSelector:@selector(retrievedAppInfo)] ? [handler retrievedAppInfo] : nil;
    if (![userInfo isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[JESSI worker] LiveProcess didn't pass the job");
        return 1;
    }
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        jessi_worker_run(userInfo);
    }];
    thread.name = @"JESSI.worker";
    thread.stackSize = 16 << 20;
    [thread start];
    [NSTimer scheduledTimerWithTimeInterval:1e9 repeats:YES block:^(NSTimer *timer) {}];
    while (1) CFRunLoopRun();
}
