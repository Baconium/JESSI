#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>
#import "JessiSettings.h"

typedef int jint;
typedef unsigned char jboolean;
#ifndef JNI_TRUE
#define JNI_TRUE 1
#endif
#ifndef JNI_FALSE
#define JNI_FALSE 0
#endif

typedef jint JLI_Launch_func(
    int argc, const char ** argv,
    int jargc, const char** jargv,
    int appclassc, const char** appclassv,
    const char* fullversion,
    const char* dotversion,
    const char* pname,
    const char* lname,
    jboolean javaargs,
    jboolean cpwildcard,
    jboolean javaw,
    jint ergo
);

static NSString *bundleJavaHomeForVersion(NSString *javaVersion) {
    NSString *bundleRoot = [[NSBundle mainBundle] bundlePath];

    NSString *versioned = [bundleRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"java%@", javaVersion]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:versioned]) return versioned;

    NSString *generic = [bundleRoot stringByAppendingPathComponent:@"java"]; 
    if ([[NSFileManager defaultManager] fileExistsAtPath:generic]) return generic;

    return nil;
}

static NSString *tmpDirPath(void) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length == 0) return @"/tmp";
    return [tmp stringByAppendingPathComponent:@"jessi"]; 
}

static void redirect_stdio_to(NSString *path) {
    if (path.length == 0) return;
    FILE *f = fopen(path.fileSystemRepresentation, "a+");
    if (!f) return;
    int fd = fileno(f);
    if (fd >= 0) {
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
    }
}

static NSArray<NSString *> *readArgsFile(NSString *path) {
    if (path.length == 0) return @[];
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) return @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        if ([t hasPrefix:@"#"]) continue;
        [out addObject:t];
    }
    return out;
}

int jessi_server_main(int argc, char *argv[]) {
    (void)[NSBundle mainBundle];
    (void)[NSFileManager defaultManager];

    @autoreleasepool {
        @try {

            if (argc < 4) {
                fprintf(stderr, "Usage: --server <jarPath> <javaVersion> <workingDir>\n");
                return 2;
            }

            const char *jarPathC = argv[1];
            const char *javaVersionC = argv[2];
            const char *workingDirC = argv[3];

            NSString *javaHome = bundleJavaHomeForVersion([NSString stringWithUTF8String:javaVersionC]);
            if (!javaHome) {
                fprintf(stderr, "Error: bundled Java runtime not found (java/ or java<ver>/)\n");
                return 3;
            }

            [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:workingDirC] withIntermediateDirectories:YES attributes:nil error:nil];

            NSString *workingDir = [NSString stringWithUTF8String:workingDirC];
            NSString *stdioLog = [workingDir stringByAppendingPathComponent:@"jessi-stdio.log"]; 
            redirect_stdio_to(stdioLog);

            NSString *tmpDir = tmpDirPath();
            [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("HOME", workingDirC, 1);
            setenv("TMPDIR", tmpDir.fileSystemRepresentation, 1);
            setenv("JAVA_HOME", javaHome.fileSystemRepresentation, 1);
            setenv("JAVA_STARTED_ON_FIRST_THREAD", "1", 1);

            setenv("JESSI_LAUNCHED_BY_JLI", "1", 1);
            setenv("JESSI_MODE", "server", 1);
            setenv("JESSI_SERVER_JAR", jarPathC, 1);
            setenv("JESSI_SERVER_JAVA_VERSION", javaVersionC, 1);
            setenv("JESSI_SERVER_WORKDIR", workingDirC, 1);

            chdir(workingDirC);

            NSString *libjliPath8 = [javaHome stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
            NSString *libjliPath11 = [javaHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
            NSString *libjliPath = [[NSFileManager defaultManager] fileExistsAtPath:libjliPath8] ? libjliPath8 : libjliPath11;

            void *libjli = dlopen(libjliPath.fileSystemRepresentation, RTLD_GLOBAL | RTLD_NOW);
            if (!libjli) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlopen(libjli) failed: %s\n", err ? err : "unknown");
                return 4;
            }

            JLI_Launch_func *JLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
            if (!JLI_Launch) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlsym(JLI_Launch) failed: %s\n", err ? err : "unknown");
                return 5;
            }

            NSString *javaPath = [javaHome stringByAppendingPathComponent:@"bin/java"]; 
            NSString *userDirArg = [@"-Duser.dir=" stringByAppendingString:workingDir];
            NSString *userHomeArg = [@"-Duser.home=" stringByAppendingString:workingDir];
            NSString *javaHomeArg = [@"-Djava.home=" stringByAppendingString:javaHome];
            NSString *tmpArg = [@"-Djava.io.tmpdir=" stringByAppendingString:tmpDir];

            NSString *frameworks = [[NSBundle mainBundle] privateFrameworksPath];
            NSString *frameworksPath = frameworks ?: @"";
            NSString *libPathArg = frameworksPath.length ? [@"-Djava.library.path=" stringByAppendingString:frameworksPath] : nil;

            NSInteger heapMB = 768;
            @try {
                heapMB = [[NSUserDefaults standardUserDefaults] integerForKey:@"jessi.maxHeapMB"]; 
                if (heapMB <= 0) heapMB = 768;
            } @catch (__unused NSException *e) {
                heapMB = 768;
            }
            NSString *xmx = [NSString stringWithFormat:@"-Xmx%ldM", (long)heapMB];
            NSString *xms = [NSString stringWithFormat:@"-Xms%ldM", (long)heapMB];

            NSString *javaVersionStr = [NSString stringWithUTF8String:javaVersionC];
            BOOL isJava17Plus = [javaVersionStr isEqualToString:@"17"] || [javaVersionStr isEqualToString:@"21"];

            BOOL flagNettyNoNative = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagNettyNoNative"];
            BOOL flagJnaNoSys = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagJnaNoSys"];

            const char *jargv[80];
            int idx = 0;
            jargv[idx++] = javaPath.UTF8String;
            jargv[idx++] = xmx.UTF8String;
            jargv[idx++] = xms.UTF8String;

            if (isJava17Plus) {
                jargv[idx++] = "-XX:-UseCompressedOops";
                jargv[idx++] = "-XX:-UseCompressedClassPointers";
            }
            
            jargv[idx++] = "-XX:+UseSerialGC";

            // iOS 26 JIT
            jargv[idx++] = "-XX:-UseCompressedOops";
            jargv[idx++] = "-XX:-UseCompressedClassPointers";
            jargv[idx++] = "-Xverify:none";

            if (flagNettyNoNative) {
                jargv[idx++] = "-Dio.netty.transport.noNative=true";
            }
            if (flagJnaNoSys) {
                jargv[idx++] = "-Djna.nosys=true";
                jargv[idx++] = "-Djna.nounpack=true";
            }
            jargv[idx++] = "-XX:MaxGCPauseMillis=50";

            if (flagNettyNoNative) {
                jargv[idx++] = "-Dio.netty.transport.noNative=true";
            }
            if (flagJnaNoSys) {
                jargv[idx++] = "-Djna.nosys=true";
                jargv[idx++] = "-Djna.nounpack=true";
            }
            jargv[idx++] = userDirArg.UTF8String;
            jargv[idx++] = userHomeArg.UTF8String;
            jargv[idx++] = javaHomeArg.UTF8String;
            jargv[idx++] = tmpArg.UTF8String;
            if (libPathArg) jargv[idx++] = libPathArg.UTF8String;
            jargv[idx++] = "-Djava.awt.headless=true";
            jargv[idx++] = "-Djava.net.preferIPv4Stack=true";
            jargv[idx++] = "-Dsun.net.client.defaultConnectTimeout=30000";
            jargv[idx++] = "-Dsun.net.client.defaultReadTimeout=30000";
            jargv[idx++] = "-Dsun.nio.ch.disableSystemWideOverlappingFileLockCheck=true";

            NSString *launchArgsPath = [workingDir stringByAppendingPathComponent:@"jessi-launch-args.txt"]; 
            NSMutableArray<NSString *> *extra = [[NSFileManager defaultManager] fileExistsAtPath:launchArgsPath] ? [readArgsFile(launchArgsPath) mutableCopy] : [NSMutableArray array];
            NSString *savedArgs = [JessiSettings shared].launchArguments ?: @"";
            if (savedArgs.length) {
                NSArray<NSString *> *parts = [savedArgs componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                for (NSString *p in parts) if (p.length) [extra addObject:p];
            }
            if (extra.count) {
                for (NSString *arg in extra) {
                    if (idx >= 78) break;
                    jargv[idx++] = arg.UTF8String;
                }
            } else {
                jargv[idx++] = "-jar";
                jargv[idx++] = jarPathC;
                jargv[idx++] = "nogui";
            }
            jargv[idx++] = NULL;

            int jargc = idx - 1;

            if ([JessiSettings shared].iOS26JITSupport) {
                printf("[JESSI] ios 26 jit support enabled");
                trigger_ios26_jit(0, 128 * 1024 * 1024);
            } else {
                printf("[JESSI] ios 26 jit support disabled");
            }

            const char *fullver = "1.8.0-internal";
            const char *dotver = "1.8";
            if ([javaVersionStr isEqualToString:@"17"]) { fullver = "17.0.0"; dotver = "17"; }
            if ([javaVersionStr isEqualToString:@"21"]) { fullver = "21.0.0"; dotver = "21"; }

            int exitCode = JLI_Launch(jargc, (const char **)jargv,
                                     0, NULL,
                                     0, NULL,
                                     fullver,
                                     dotver,
                                     "java",
                                     "openjdk",
                                     JNI_FALSE,
                                     JNI_TRUE,
                                     JNI_FALSE,
                                     JNI_TRUE);
            return exitCode;
        }
        @catch (NSException *e) {
            fprintf(stderr, "JVM launch threw exception: %s\n", e.reason.UTF8String ?: "(no reason)");
            return 250;
        }
        @catch (...) {
            fprintf(stderr, "JVM launch threw unknown C++ exception\n");
            return 249;
        }
    }
}

int jessi_tool_main(int argc, char *argv[]) {
    (void)[NSBundle mainBundle];
    (void)[NSFileManager defaultManager];

    @autoreleasepool {
        @try {

            if (argc < 4) {
                fprintf(stderr, "Usage: --tool <jarPath> <javaVersion> <workingDir> [argsFile]\n");
                return 2;
            }

            const char *jarPathC = argv[1];
            const char *javaVersionC = argv[2];
            const char *workingDirC = argv[3];
            const char *argsPathC = (argc >= 5 && argv[4] && argv[4][0]) ? argv[4] : NULL;

            NSString *javaHome = bundleJavaHomeForVersion([NSString stringWithUTF8String:javaVersionC]);
            if (!javaHome) {
                fprintf(stderr, "Error: bundled Java runtime not found (java/ or java<ver>/)\n");
                return 3;
            }

            [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:workingDirC] withIntermediateDirectories:YES attributes:nil error:nil];

            NSString *workingDir = [NSString stringWithUTF8String:workingDirC];
            NSString *stdioLog = [workingDir stringByAppendingPathComponent:@"jessi-tool-stdio.log"]; 
            redirect_stdio_to(stdioLog);

            NSString *tmpDir = tmpDirPath();
            [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("HOME", workingDirC, 1);
            setenv("TMPDIR", tmpDir.fileSystemRepresentation, 1);
            setenv("JAVA_HOME", javaHome.fileSystemRepresentation, 1);
            setenv("JAVA_STARTED_ON_FIRST_THREAD", "1", 1);

            setenv("JESSI_LAUNCHED_BY_JLI", "1", 1);
            setenv("JESSI_MODE", "tool", 1);
            setenv("JESSI_TOOL_JAR", jarPathC, 1);
            setenv("JESSI_TOOL_JAVA_VERSION", javaVersionC, 1);
            setenv("JESSI_TOOL_WORKDIR", workingDirC, 1);
            if (argsPathC) setenv("JESSI_TOOL_ARGS_PATH", argsPathC, 1);

            chdir(workingDirC);

            NSString *libjliPath8 = [javaHome stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
            NSString *libjliPath11 = [javaHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
            NSString *libjliPath = [[NSFileManager defaultManager] fileExistsAtPath:libjliPath8] ? libjliPath8 : libjliPath11;

            void *libjli = dlopen(libjliPath.fileSystemRepresentation, RTLD_GLOBAL | RTLD_NOW);
            if (!libjli) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlopen(libjli) failed: %s\n", err ? err : "unknown");
                return 4;
            }

            JLI_Launch_func *JLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
            if (!JLI_Launch) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlsym(JLI_Launch) failed: %s\n", err ? err : "unknown");
                return 5;
            }

            NSString *javaPath = [javaHome stringByAppendingPathComponent:@"bin/java"]; 
            NSString *userDirArg = [@"-Duser.dir=" stringByAppendingString:workingDir];
            NSString *userHomeArg = [@"-Duser.home=" stringByAppendingString:workingDir];
            NSString *javaHomeArg = [@"-Djava.home=" stringByAppendingString:javaHome];
            NSString *tmpArg = [@"-Djava.io.tmpdir=" stringByAppendingString:tmpDir];

            NSString *frameworks = [[NSBundle mainBundle] privateFrameworksPath];
            NSString *frameworksPath = frameworks ?: @"";
            NSString *libPathArg = frameworksPath.length ? [@"-Djava.library.path=" stringByAppendingString:frameworksPath] : nil;

            NSString *xmx = @"-Xmx512M";
            NSString *xms = @"-Xms16M";

            NSString *maxMeta = @"-XX:MaxMetaspaceSize=256M";

            NSString *javaVersionStr = [NSString stringWithUTF8String:javaVersionC];

            BOOL flagNettyNoNative = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagNettyNoNative"];
            BOOL flagJnaNoSys = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagJnaNoSys"];

            NSArray<NSString *> *extra = argsPathC ? readArgsFile([NSString stringWithUTF8String:argsPathC]) : @[];

            const char *jargv[96];
            int idx = 0;
            jargv[idx++] = javaPath.UTF8String;
            jargv[idx++] = xmx.UTF8String;
            jargv[idx++] = xms.UTF8String;
            jargv[idx++] = "-XX:+UseSerialGC";

            if (flagNettyNoNative) {
                jargv[idx++] = "-Dio.netty.transport.noNative=true";
            }
            if (flagJnaNoSys) {
                jargv[idx++] = "-Djna.nosys=true";
                jargv[idx++] = "-Djna.nounpack=true";
            }
            jargv[idx++] = maxMeta.UTF8String;
            jargv[idx++] = userDirArg.UTF8String;
            jargv[idx++] = userHomeArg.UTF8String;
            jargv[idx++] = javaHomeArg.UTF8String;
            jargv[idx++] = tmpArg.UTF8String;
            if (libPathArg) jargv[idx++] = libPathArg.UTF8String;
            jargv[idx++] = "-Djava.awt.headless=true";
            jargv[idx++] = "-Djava.net.preferIPv4Stack=true";
            jargv[idx++] = "-jar";
            jargv[idx++] = jarPathC;
            for (NSString *arg in extra) {
                if (idx >= 94) break;
                jargv[idx++] = arg.UTF8String;
            }
            jargv[idx++] = NULL;

            int jargc = idx - 1;

            const char *fullver = "1.8.0-internal";
            const char *dotver = "1.8";
            if ([javaVersionStr isEqualToString:@"17"]) { fullver = "17.0.0"; dotver = "17"; }
            if ([javaVersionStr isEqualToString:@"21"]) { fullver = "21.0.0"; dotver = "21"; }

            int exitCode = JLI_Launch(jargc, (const char **)jargv,
                                     0, NULL,
                                     0, NULL,
                                     fullver,
                                     dotver,
                                     "java",
                                     "openjdk",
                                     JNI_FALSE,
                                     JNI_TRUE,
                                     JNI_FALSE,
                                     JNI_TRUE);
            return exitCode;
        }
        @catch (NSException *e) {
            fprintf(stderr, "Java tool launch threw exception: %s\n", e.reason.UTF8String ?: "(no reason)");
            return 250;
        }
        @catch (...) {
            fprintf(stderr, "Java tool launch threw unknown C++ exception\n");
            return 249;
        }
    }
}
