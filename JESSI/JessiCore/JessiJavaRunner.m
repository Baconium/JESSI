#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>
#import <dirent.h>
#import <signal.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/mman.h>
#import <mach/mach.h>
#import <mach-o/dyld_images.h>
#import <libkern/OSCacheControl.h>
#import <pthread.h>
#import <mach/arm/thread_status.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <sys/stat.h>
#import <sys/mman.h>
#import <fcntl.h>
#import "JessiSettings.h"
#import "../SwiftUI/JessiJITCheck.h"

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef CS_OPS_ENTITLEMENTS_BLOB
#define CS_OPS_ENTITLEMENTS_BLOB 7
#endif

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif

#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

static BOOL jessi_is_cs_debugged(void) {
    int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
    return (flags & CS_DEBUGGED) != 0;
}

static BOOL jessi_task_has_breakpoint_exception_handler(void) {
    exception_mask_t masks[32];
    mach_msg_type_number_t masksCnt = 32;
    exception_handler_t handlers[32];
    exception_behavior_t behaviors[32];
    thread_state_flavor_t flavors[32];

    kern_return_t kr = task_get_exception_ports(mach_task_self(), EXC_MASK_BREAKPOINT,
                                                masks, &masksCnt, handlers, behaviors, flavors);
    if (kr != KERN_SUCCESS) return NO;

    BOOL hasHandler = NO;
    for (mach_msg_type_number_t i = 0; i < masksCnt; i++) {
        if ((masks[i] & EXC_MASK_BREAKPOINT) && handlers[i] != MACH_PORT_NULL) {
            hasHandler = YES;
        }
        if (handlers[i] != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), handlers[i]);
        }
    }
    return hasHandler;
}

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

static BOOL jessi_is_ios26_or_later_core(void) {
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    return v.majorVersion >= 26;
}

static BOOL jessi_has_extended_va_entitlement(void) {
    
    

    pid_t pid = getpid();
    size_t cap = 4096;
    void *buf = NULL;
    int rc = -1;

    for (int i = 0; i < 7; i++) {
        free(buf);
        buf = calloc(1, cap);
        if (!buf) return NO;

        errno = 0;
        rc = csops(pid, CS_OPS_ENTITLEMENTS_BLOB, buf, (uint32_t)cap);
        if (rc == 0) break;

        if (errno == ERANGE) {
            cap *= 2;
            continue;
        }

        free(buf);
        return NO;
    }

    if (rc != 0) {
        free(buf);
        return NO;
    }

    size_t len = strnlen((const char *)buf, cap);
    if (len == 0 || len == cap) len = cap;

    NSData *data = [NSData dataWithBytesNoCopy:buf length:len freeWhenDone:YES];
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![plist isKindOfClass:[NSDictionary class]]) return NO;

    NSDictionary *entitlements = (NSDictionary *)plist;
    id val = entitlements[@"com.apple.developer.kernel.extended-virtual-addressing"];
    if ([val respondsToSelector:@selector(boolValue)] && [val boolValue]) return YES;

    
    val = entitlements[@"com.apple.private.kernel.extended-virtual-addressing"];
    if ([val respondsToSelector:@selector(boolValue)] && [val boolValue]) return YES;

    return NO;
}

__attribute__((noinline,optnone,naked))
static void jessi_jit26_break_send_script(char *script, size_t len) {
    __asm__(
        "mov x16, #2 \n"
        "brk #0xf00d \n"
        "ret"
    );
}

__attribute__((noinline,optnone,naked))
static void jessi_jit26_set_detach_after_first_br(BOOL value) {
    __asm__(
        "mov x16, #3 \n"
        "brk #0xf00d \n"
        "ret"
    );
}

static BOOL jessi_device_requires_txm_workaround(void) {
    static int cached = -1;
    if (cached != -1) return cached == 1;

    if (!jessi_is_ios26_or_later_core()) {
        cached = 0;
        return NO;
    }

    DIR *d = opendir("/private/preboot");
    if (!d) {
        cached = 0;
        return NO;
    }

    struct dirent *dir;
    char txmPath[PATH_MAX] = {0};
    while ((dir = readdir(d)) != NULL) {
        if (strlen(dir->d_name) == 96) {
            snprintf(txmPath, sizeof(txmPath), "/private/preboot/%s/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", dir->d_name);
            break;
        }
    }
    closedir(d);

    cached = (txmPath[0] != 0 && access(txmPath, F_OK) == 0) ? 1 : 0;
    return cached == 1;
}

static BOOL jessi_txm_jit26_ready = NO;

static NSString *jessi_find_jit26_extension_script(NSString *workingDir) {
    if (workingDir.length) {
        NSString *fromWorkdir = [workingDir stringByAppendingPathComponent:@"UniversalJIT26Extension.js"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:fromWorkdir]) {
            return fromWorkdir;
        }
    }

    NSString *fromBundle = [[NSBundle mainBundle] pathForResource:@"UniversalJIT26Extension" ofType:@"js"];
    if (fromBundle.length && [[NSFileManager defaultManager] fileExistsAtPath:fromBundle]) {
        return fromBundle;
    }

    return nil;
}

static void jessi_ios26_txm_setup_if_needed(NSString *workingDir) {
    static BOOL didSetup = NO;
    if (didSetup) return;

    if (!jessi_is_ios26_or_later_core()) return;
    if (!jessi_device_requires_txm_workaround()) return;

    if (![JessiSettings shared].iOS26JITSupport) {
        fprintf(stderr, "[JESSI] TXM device detected; TXM Support is OFF (Settings).\n");
        return;
    }

    NSString *scriptPath = jessi_find_jit26_extension_script(workingDir);
    if (!scriptPath.length) {
        fprintf(stderr, "[JESSI] TXM Support enabled but UniversalJIT26Extension.js not found.\n");
        fprintf(stderr, "[JESSI] Relying on external debugger breakpoint handler for JIT.\n");
        BOOL hasHandler = jessi_task_has_breakpoint_exception_handler();
        fprintf(stderr, "[JESSI] TXM setup: CS_DEBUGGED=%d, hasBreakpointHandler=%d\n", jessi_is_cs_debugged() ? 1 : 0, hasHandler ? 1 : 0);
        if (!hasHandler) {
            fprintf(stderr, "[JESSI] TXM setup skipped (no breakpoint handler)\n");
            return;
        }

        didSetup = YES;
        return;
    }

    NSError *err = nil;
    NSString *script = [NSString stringWithContentsOfFile:scriptPath encoding:NSUTF8StringEncoding error:&err];
    if (!script.length || err) {
        fprintf(stderr, "[JESSI] Failed to read UniversalJIT26Extension.js: %s\n", err.localizedDescription.UTF8String ?: "unknown");
        return;
    }

    didSetup = YES;
    fprintf(stderr, "[JESSI] TXM setup: sending UniversalJIT26Extension (%s)\n", scriptPath.lastPathComponent.UTF8String);
    jessi_jit26_break_send_script((char *)script.UTF8String, (size_t)script.length);
    jessi_txm_jit26_ready = YES;
    jessi_jit26_set_detach_after_first_br(NO);

    kern_return_t kr = task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[JESSI] TXM setup: task_set_exception_ports(EXC_MASK_BAD_ACCESS) failed: %d\n", kr);
    }
}

static NSArray<NSString *> *jessi_filter_extra_jvm_args(NSArray<NSString *> *args, BOOL ios26OrLater, BOOL isJava17Plus) {
    if (args.count == 0) return args;

    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:args.count];
    for (NSString *arg in args) {
        if (arg.length == 0) continue;

        
        if (!ios26OrLater) {
            if ([arg rangeOfString:@"MirrorMappedCodeCache"].location != NSNotFound) continue;
            if ([arg isEqualToString:@"-Xverify:none"]) continue;
            if ([arg isEqualToString:@"-XX:-UseCompressedOops"]) continue;
            if ([arg isEqualToString:@"-XX:-UseCompressedClassPointers"]) continue;
        }

        
        if (!isJava17Plus && [arg rangeOfString:@"MirrorMappedCodeCache"].location != NSNotFound) {
            continue;
        }

        [out addObject:arg];
    }
    return out;
}

static BOOL jessi_args_contain_prefix(NSArray<NSString *> *args, NSString *prefix) {
    if (args.count == 0 || prefix.length == 0) return NO;
    for (NSString *arg in args) {
        if ([arg hasPrefix:prefix]) return YES;
    }
    return NO;
}

static NSString *bundleJavaHomeForVersion(NSString *javaVersion) {
    NSURL *appSupport = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask] firstObject];
    NSString *runtimesRoot = [[appSupport URLByAppendingPathComponent:@"Runtimes" isDirectory:YES] path];
    if (runtimesRoot.length) {
        NSString *installed = [runtimesRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"jre%@", javaVersion]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:installed]) return installed;
    }

    return nil;
}

static NSString *bundledJvmHomeForVersion(NSString *javaVersion) {
    if (javaVersion.length == 0) return nil;
    NSString *bundleRoot = [[NSBundle mainBundle] bundlePath];

    NSString *dirName = [@"java" stringByAppendingString:javaVersion];
    if ([javaVersion isEqualToString:@"8"]) dirName = @"java8";

    NSString *home = [[bundleRoot stringByAppendingPathComponent:@"JVM"] stringByAppendingPathComponent:dirName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:home]) return home;
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
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
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

            [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:workingDirC]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];

            NSString *workingDir = [NSString stringWithUTF8String:workingDirC];
            NSString *stdioLog = [workingDir stringByAppendingPathComponent:@"jessi-stdio.log"]; 
            redirect_stdio_to(stdioLog);

            fprintf(stderr, "[JESSI] Server start (java=%s, workdir=%s)\n", javaVersionC, workingDirC);

            NSString *javaHome = bundleJavaHomeForVersion([NSString stringWithUTF8String:javaVersionC]);
            if (!javaHome) {
                fprintf(stderr, "Error: Java runtime not found. Expected Application Support: Runtimes/jre<ver>/.\n");
                return 3;
            }

            NSString *jvmHome = bundledJvmHomeForVersion([NSString stringWithUTF8String:javaVersionC]);
            if (!jvmHome) {
                fprintf(stderr, "Error: Bundled JVM dylibs not found for Java %s. Expected app bundle: JVM/java<ver>/\n", javaVersionC);
                return 6;
            }

            NSString *tmpDir = tmpDirPath();
            [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("HOME", workingDirC, 1);
            setenv("TMPDIR", tmpDir.fileSystemRepresentation, 1);
            setenv("JAVA_HOME", javaHome.fileSystemRepresentation, 1);
            setenv("JAVA_STARTED_ON_FIRST_THREAD", "1", 1);
            setenv("JESSI_BUNDLED_JVM_HOME", jvmHome.fileSystemRepresentation, 1);

            setenv("JESSI_LAUNCHED_BY_JLI", "1", 1);
            setenv("JESSI_MODE", "server", 1);
            setenv("JESSI_SERVER_JAR", jarPathC, 1);
            setenv("JESSI_SERVER_JAVA_VERSION", javaVersionC, 1);
            setenv("JESSI_SERVER_WORKDIR", workingDirC, 1);

            chdir(workingDirC);
            jessi_ios26_txm_setup_if_needed(workingDir);

            NSString *libjliPath8 = [jvmHome stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
            NSString *libjliPath11 = [jvmHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
            NSString *libjliPath = [[NSFileManager defaultManager] fileExistsAtPath:libjliPath8] ? libjliPath8 : libjliPath11;

            (void)dlerror();
            void *libjli = dlopen(libjliPath.fileSystemRepresentation, RTLD_GLOBAL | RTLD_NOW);
            if (!libjli) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlopen(libjli) failed: %s\n", err ? err : "unknown");
                fprintf(stderr, "[JESSI] Expected to load JVM dylibs from the app bundle (JVM/java<ver>/...).\n");
                fprintf(stderr, "[JESSI] Hint: iOS enforces code signing/library validation for Mach-O dylibs; downloaded dylibs in Application Support usually won't load.\n");
                return 4;
            }

            JLI_Launch_func *JLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
            if (!JLI_Launch) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlsym(JLI_Launch) failed: %s\n", err ? err : "unknown");
                return 5;
            }

            NSString *javaPath = [jvmHome stringByAppendingPathComponent:@"bin/java"]; 
            NSString *userDirArg = [@"-Duser.dir=" stringByAppendingString:workingDir];
            NSString *userHomeArg = [@"-Duser.home=" stringByAppendingString:workingDir];
            NSString *javaHomeArg = [@"-Djava.home=" stringByAppendingString:javaHome];
            NSString *tmpArg = [@"-Djava.io.tmpdir=" stringByAppendingString:tmpDir];

            NSString *frameworks = [[NSBundle mainBundle] privateFrameworksPath];
            NSString *frameworksPath = frameworks ?: @"";
            NSString *bundledLib = [jvmHome stringByAppendingPathComponent:@"lib"];
            NSString *bundledServerLib = [jvmHome stringByAppendingPathComponent:@"lib/server"];
            NSString *bundledJliLib = [jvmHome stringByAppendingPathComponent:@"lib/jli"];
            NSString *combinedLibPath = [NSString stringWithFormat:@"%@:%@:%@%@%@",
                                         bundledLib,
                                         bundledServerLib,
                                         bundledJliLib,
                                         frameworksPath.length ? @":" : @"",
                                         frameworksPath.length ? frameworksPath : @""];
            NSString *libPathArg = combinedLibPath.length ? [@"-Djava.library.path=" stringByAppendingString:combinedLibPath] : nil;

            NSInteger iosMajor = [NSProcessInfo processInfo].operatingSystemVersion.majorVersion;

            NSInteger heapMB = 768;
            @try {
                heapMB = [[NSUserDefaults standardUserDefaults] integerForKey:@"jessi.maxHeapMB"]; 
                if (heapMB <= 0) heapMB = 768;
            } @catch (__unused NSException *e) {
                heapMB = 768;
            }

            
            NSInteger initialHeapMB = MIN(heapMB, 256);
            @try {
                NSInteger configuredInitial = [[NSUserDefaults standardUserDefaults] integerForKey:@"jessi.initialHeapMB"];
                if (configuredInitial > 0) initialHeapMB = configuredInitial;
            } @catch (__unused NSException *e) {
                
            }
            if (initialHeapMB <= 0) initialHeapMB = MIN(heapMB, 256);
            if (initialHeapMB > heapMB) initialHeapMB = heapMB;

            NSString *xmx = [NSString stringWithFormat:@"-Xmx%ldM", (long)heapMB];
            NSString *xms = [NSString stringWithFormat:@"-Xms%ldM", (long)initialHeapMB];

            NSString *javaVersionStr = [NSString stringWithUTF8String:javaVersionC];
            BOOL isJava17Plus = [javaVersionStr isEqualToString:@"17"] || [javaVersionStr isEqualToString:@"21"];
            BOOL ios26OrLater = jessi_is_ios26_or_later_core();

            BOOL flagNettyNoNative = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagNettyNoNative"];
            BOOL flagJnaNoSys = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagJnaNoSys"];

            const char *jargv[80];
            int idx = 0;
            jargv[idx++] = javaPath.UTF8String;
            jargv[idx++] = xmx.UTF8String;
            jargv[idx++] = xms.UTF8String;

            fprintf(stderr, "[JESSI] Launching JVM (iOS%ld, Java %s)\n", (long)iosMajor, javaVersionC);

            
            if (ios26OrLater) {
                jargv[idx++] = "-XX:+UnlockExperimentalVMOptions";
                jargv[idx++] = "-XX:+DisablePrimordialThreadGuardPages";
            }
            
            if (ios26OrLater && isJava17Plus) {
                jargv[idx++] = "-XX:+MirrorMappedCodeCache";
            }
            
            if (isJava17Plus && !jessi_has_extended_va_entitlement()) {
                jargv[idx++] = "-XX:-UseCompressedClassPointers";
            }
            
            jargv[idx++] = "-XX:+UseSerialGC";

            
            
            NSString *launchArgsPath = [workingDir stringByAppendingPathComponent:@"jessi-launch-args.txt"]; 
            NSMutableArray<NSString *> *extra = [[NSFileManager defaultManager] fileExistsAtPath:launchArgsPath] ? [readArgsFile(launchArgsPath) mutableCopy] : [NSMutableArray array];
            NSString *savedArgs = [JessiSettings shared].launchArguments ?: @"";
            if (savedArgs.length) {
                NSArray<NSString *> *parts = [savedArgs componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                for (NSString *p in parts) if (p.length) [extra addObject:p];
            }
            
            NSMutableArray<NSString *> *filteredExtra = [[jessi_filter_extra_jvm_args(extra, ios26OrLater, isJava17Plus) mutableCopy] mutableCopy];
            if (filteredExtra) {
                extra = filteredExtra;
            }

            BOOL userSetCodeCache = jessi_args_contain_prefix(extra, @"-XX:ReservedCodeCacheSize=");
            
            if (!ios26OrLater && iosMajor <= 18) {
                if (!userSetCodeCache) {
                    jargv[idx++] = "-XX:ReservedCodeCacheSize=64M";
                }
            }

            if (flagNettyNoNative) {
                jargv[idx++] = "-Dio.netty.transport.noNative=true";
            }
            if (flagJnaNoSys) {
                jargv[idx++] = "-Djna.nosys=true";
                jargv[idx++] = "-Djna.nounpack=true";
            }
            jargv[idx++] = "-XX:MaxGCPauseMillis=50";
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

            
            signal(SIGSEGV, SIG_DFL);
            signal(SIGPIPE, SIG_DFL);
            signal(SIGBUS, SIG_DFL);
            signal(SIGILL, SIG_DFL);
            signal(SIGFPE, SIG_DFL);

            const char *fullver = "1.8.0-internal";
            const char *dotver = "1.8";
            if ([javaVersionStr isEqualToString:@"17"]) { fullver = "17.0.0"; dotver = "17"; }
            if ([javaVersionStr isEqualToString:@"21"]) { fullver = "21.0.0"; dotver = "21"; }

            jint result = JLI_Launch(jargc, (const char **)jargv,
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
            return (int)result;
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

            [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:workingDirC]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];

            NSString *workingDir = [NSString stringWithUTF8String:workingDirC];
            NSString *stdioLog = [workingDir stringByAppendingPathComponent:@"jessi-tool-stdio.log"]; 
            redirect_stdio_to(stdioLog);

            fprintf(stderr, "[JESSI] Tool start (java=%s, workdir=%s)\n", javaVersionC, workingDirC);

            NSString *javaHome = bundleJavaHomeForVersion([NSString stringWithUTF8String:javaVersionC]);
            if (!javaHome) {
                fprintf(stderr, "Error: Java runtime not found. Expected Application Support: Runtimes/jre<ver>/.\n");
                return 3;
            }

            NSString *jvmHome = bundledJvmHomeForVersion([NSString stringWithUTF8String:javaVersionC]);
            if (!jvmHome) {
                fprintf(stderr, "Error: Bundled JVM dylibs not found for Java %s. Expected app bundle: JVM/java<ver>/\n", javaVersionC);
                return 6;
            }

            NSString *tmpDir = tmpDirPath();
            [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("HOME", workingDirC, 1);
            setenv("TMPDIR", tmpDir.fileSystemRepresentation, 1);
            setenv("JAVA_HOME", javaHome.fileSystemRepresentation, 1);
            setenv("JAVA_STARTED_ON_FIRST_THREAD", "1", 1);
            setenv("JESSI_BUNDLED_JVM_HOME", jvmHome.fileSystemRepresentation, 1);

            setenv("JESSI_LAUNCHED_BY_JLI", "1", 1);
            setenv("JESSI_MODE", "tool", 1);
            setenv("JESSI_TOOL_JAR", jarPathC, 1);
            setenv("JESSI_TOOL_JAVA_VERSION", javaVersionC, 1);
            setenv("JESSI_TOOL_WORKDIR", workingDirC, 1);
            if (argsPathC) setenv("JESSI_TOOL_ARGS_PATH", argsPathC, 1);

            chdir(workingDirC);

            jessi_ios26_txm_setup_if_needed(workingDir);

            NSString *libjliPath8 = [jvmHome stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
            NSString *libjliPath11 = [jvmHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
            NSString *libjliPath = [[NSFileManager defaultManager] fileExistsAtPath:libjliPath8] ? libjliPath8 : libjliPath11;

            (void)dlerror();
            void *libjli = dlopen(libjliPath.fileSystemRepresentation, RTLD_GLOBAL | RTLD_NOW);
            if (!libjli) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlopen(libjli) failed: %s\n", err ? err : "unknown");
                fprintf(stderr, "[JESSI] Expected to load JVM dylibs from the app bundle (JVM/java<ver>/...).\n");
                return 4;
            }

            JLI_Launch_func *JLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
            if (!JLI_Launch) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlsym(JLI_Launch) failed: %s\n", err ? err : "unknown");
                return 5;
            }

            NSString *javaPath = [jvmHome stringByAppendingPathComponent:@"bin/java"]; 
            NSString *userDirArg = [@"-Duser.dir=" stringByAppendingString:workingDir];
            NSString *userHomeArg = [@"-Duser.home=" stringByAppendingString:workingDir];
            NSString *javaHomeArg = [@"-Djava.home=" stringByAppendingString:javaHome];
            NSString *tmpArg = [@"-Djava.io.tmpdir=" stringByAppendingString:tmpDir];

            NSString *frameworks = [[NSBundle mainBundle] privateFrameworksPath];
            NSString *frameworksPath = frameworks ?: @"";
            NSString *bundledLib = [jvmHome stringByAppendingPathComponent:@"lib"];
            NSString *bundledServerLib = [jvmHome stringByAppendingPathComponent:@"lib/server"];
            NSString *bundledJliLib = [jvmHome stringByAppendingPathComponent:@"lib/jli"];
            NSString *combinedLibPath = [NSString stringWithFormat:@"%@:%@:%@%@%@",
                                         bundledLib,
                                         bundledServerLib,
                                         bundledJliLib,
                                         frameworksPath.length ? @":" : @"",
                                         frameworksPath.length ? frameworksPath : @""];
            NSString *libPathArg = combinedLibPath.length ? [@"-Djava.library.path=" stringByAppendingString:combinedLibPath] : nil;

            NSString *xmx = @"-Xmx512M";
            NSString *xms = @"-Xms16M";

            NSString *maxMeta = @"-XX:MaxMetaspaceSize=256M";

            NSString *javaVersionStr = [NSString stringWithUTF8String:javaVersionC];
            BOOL ios26OrLater = jessi_is_ios26_or_later_core();

            BOOL flagNettyNoNative = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagNettyNoNative"];
            BOOL flagJnaNoSys = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagJnaNoSys"];

            NSArray<NSString *> *extraRaw = argsPathC ? readArgsFile([NSString stringWithUTF8String:argsPathC]) : @[];
            NSArray<NSString *> *extra = jessi_filter_extra_jvm_args(extraRaw, ios26OrLater, [javaVersionStr isEqualToString:@"17"] || [javaVersionStr isEqualToString:@"21"]);

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

            jint result = JLI_Launch(jargc, (const char **)jargv,
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
            return (int)result;
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
