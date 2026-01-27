#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <pthread.h>
#import <string.h>
#import <stdlib.h>

#import "JessiAppDelegate.h"

int jessi_server_main(int argc, char *argv[]);
int jessi_tool_main(int argc, char *argv[]);

static BOOL streq(const char *a, const char *b) {
    return (a && b && strcmp(a, b) == 0);
}

static const char *getenv_nonempty(const char *k) {
    const char *v = getenv(k);
    return (v && *v) ? v : NULL;
}

int main(int argc, char *argv[]) {
    static BOOL s_appLaunched = NO;

    BOOL isMainThread = pthread_main_np() != 0;

    if (argc > 1 && argv[1] && streq(argv[1], "--server")) {
        return jessi_server_main(argc - 1, argv + 1);
    }

    if (argc > 1 && argv[1] && streq(argv[1], "--tool")) {
        return jessi_tool_main(argc - 1, argv + 1);
    }

    const char *jliRelaunch = getenv_nonempty("JESSI_LAUNCHED_BY_JLI");
    if (jliRelaunch) {
        const char *mode = getenv_nonempty("JESSI_MODE");

        if (mode && streq(mode, "tool")) {
            const char *jar = getenv_nonempty("JESSI_TOOL_JAR");
            const char *ver = getenv_nonempty("JESSI_TOOL_JAVA_VERSION");
            const char *wd  = getenv_nonempty("JESSI_TOOL_WORKDIR");
            const char *argsPath  = getenv_nonempty("JESSI_TOOL_ARGS_PATH");

            if (jar && ver && wd) {
                char *argv0 = "--tool";
                char *argv1 = (char *)jar;
                char *argv2 = (char *)ver;
                char *argv3 = (char *)wd;
                char *argv4 = (char *)(argsPath ? argsPath : "");
                char *argvv[] = { argv0, argv1, argv2, argv3, argv4, NULL };
                return jessi_tool_main(argsPath ? 5 : 4, argvv);
            }

            return 0;
        }

        const char *jar = getenv_nonempty("JESSI_SERVER_JAR");
        const char *ver = getenv_nonempty("JESSI_SERVER_JAVA_VERSION");
        const char *wd  = getenv_nonempty("JESSI_SERVER_WORKDIR");

        if (jar && ver && wd) {
            char *argv0 = "--server";
            char *argv1 = (char *)jar;
            char *argv2 = (char *)ver;
            char *argv3 = (char *)wd;
            char *argvv[] = { argv0, argv1, argv2, argv3, NULL };
            return jessi_server_main(4, argvv);
        }

        return 0;
    }

    if (s_appLaunched) {
        return 0;
    }
    s_appLaunched = YES;

    if (!isMainThread) {
        return 0;
    }

    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([JessiAppDelegate class]));
    }
}
