#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <fcntl.h>
#import <spawn.h>
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
#import <dirent.h>
#import <limits.h>
#import <sys/ucontext.h>
#if __has_include(<sys/fcntl.h>)
#import <sys/fcntl.h>
#endif
#import "JessiSettings.h"
#import "../SwiftUI/JessiJITCheck.h"
#import "MachExc/mach_excServer.h"

#ifndef JESSI_TXM_DEBUG_LOGGING
#define JESSI_TXM_DEBUG_LOGGING 0
#endif
#if JESSI_TXM_DEBUG_LOGGING
#define JESSI_TXM_LOG(...) fprintf(stderr, __VA_ARGS__)
#else
#define JESSI_TXM_LOG(...) do { } while (0)
#endif

extern boolean_t mach_exc_server(mach_msg_header_t *InHeadP, mach_msg_header_t *OutHeadP);

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef CS_OPS_ENTITLEMENTS_BLOB
#define CS_OPS_ENTITLEMENTS_BLOB 7
#endif

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

static BOOL jessi_is_ios26_or_later_core(void);

static void *jessi_jit26_prepare_region(void *addr, size_t len);

static struct sigaction jessi_prev_sigtrap_action;
static BOOL jessi_sigtrap_fallback_installed = NO;

static void jessi_sigtrap_fallback_handler(int sig, siginfo_t *info, void *uap) {
    (void)info;

    if (sig != SIGTRAP || !uap) {
        goto chain;
    }

    ucontext_t *uc = (ucontext_t *)uap;
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    if (pc == 0) goto chain;

    uint32_t instr = 0;
    instr = *(const uint32_t *)(uintptr_t)pc;

    if (((instr & 0xFFE0001Fu) != 0xD4200000u)) {
        goto chain;
    }

    uint32_t brkImm = (instr >> 5) & 0xFFFFu;
    if (brkImm != 0xF00Du && brkImm != 0x0069u) {
        goto chain;
    }

    uc->uc_mcontext->__ss.__pc = pc + 4;
    if (brkImm == 0xF00Du) {
        uc->uc_mcontext->__ss.__x[0] = 0xE000F00Du;
    } else {
        uc->uc_mcontext->__ss.__x[0] = 0;
    }
    return;

chain:
    if (jessi_prev_sigtrap_action.sa_flags & SA_SIGINFO) {
        if (jessi_prev_sigtrap_action.sa_sigaction) {
            jessi_prev_sigtrap_action.sa_sigaction(sig, info, uap);
            return;
        }
    } else {
        if (jessi_prev_sigtrap_action.sa_handler == SIG_IGN) return;
        if (jessi_prev_sigtrap_action.sa_handler && jessi_prev_sigtrap_action.sa_handler != SIG_DFL) {
            jessi_prev_sigtrap_action.sa_handler(sig);
            return;
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void jessi_install_sigtrap_fallback_if_needed(void) {
    if (jessi_sigtrap_fallback_installed) return;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = jessi_sigtrap_fallback_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    if (sigaction(SIGTRAP, &sa, &jessi_prev_sigtrap_action) == 0) {
        jessi_sigtrap_fallback_installed = YES;
    }
}

static BOOL jessi_jit26_prepare_region_chunked(void *addr, size_t len) {
    if (!addr || len == 0) return NO;
    const size_t chunk = 1u << 20;
    uint8_t *p = (uint8_t *)addr;
    size_t remaining = len;
    while (remaining > 0) {
        size_t n = remaining > chunk ? chunk : remaining;
        void *prepared = jessi_jit26_prepare_region(p, n);
        if (!prepared || prepared == (void *)(uintptr_t)0xE000F00Du) {
            return NO;
        }
        p += n;
        remaining -= n;
    }
    return YES;
}

__attribute__((noinline,optnone,naked))
static void *jessi_jit26_prepare_region(void *addr, size_t len) {
    asm("mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret");
}

__attribute__((noinline,optnone,naked))
static void jessi_jit26_prepare_region_for_patching(void *addr, size_t size) {
    asm("mov x16, #4 \n"
        "brk #0xf00d \n"
        "ret");
}

__attribute__((noinline,optnone,naked))
static void jessi_jit26_send_script(const char *script, size_t len) {
    asm("mov x16, #2 \n"
        "brk #0xf00d \n"
        "ret");
}

__attribute__((noinline,optnone,naked))
static void jessi_jit26_set_detach_after_first_br(BOOL value) {
    asm("mov x16, #3 \n"
        "brk #0xf00d \n"
        "ret");
}

__attribute__((noinline,optnone,naked))
static void *jessi_jit26_create_region_legacy(size_t size) {
    asm("brk #0x69 \n"
        "ret");
}

static BOOL jessi_send_jit26_extension_script(void) {
    NSString *scriptPath = [[NSBundle mainBundle] pathForResource:@"UniversalJIT26Extension" ofType:@"js"];
    if (!scriptPath) {
        JESSI_TXM_LOG("[JESSI] UniversalJIT26Extension.js not found in bundle\n");
        return NO;
    }
    NSString *script = [NSString stringWithContentsOfFile:scriptPath encoding:NSUTF8StringEncoding error:nil];
    if (!script || script.length == 0) {
        JESSI_TXM_LOG("[JESSI] Failed to read UniversalJIT26Extension.js\n");
        return NO;
    }
    JESSI_TXM_LOG("[JESSI] Sending JIT26 extension script (%lu bytes)\n", (unsigned long)script.length);
    jessi_jit26_send_script(script.UTF8String, strlen(script.UTF8String));
    JESSI_TXM_LOG("[JESSI] JIT26 extension script sent\n");
    return YES;
}

static BOOL jessi_device_requires_txm_workaround(void) {
    if (!jessi_is_ios26_or_later_core()) return NO;

    DIR *d = opendir("/private/preboot");
    if (!d) return NO;

    struct dirent *dir = NULL;
    char txmPath[PATH_MAX] = {0};
    while ((dir = readdir(d)) != NULL) {
        if (strlen(dir->d_name) == 96) {
            snprintf(txmPath, sizeof(txmPath), "/private/preboot/%s/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", dir->d_name);
            break;
        }
    }
    closedir(d);

    BOOL hasTxm = txmPath[0] != '\0' && access(txmPath, F_OK) == 0;
    JESSI_TXM_LOG("[JESSI] TXM probe path=%s present=%d\n", txmPath[0] ? txmPath : "(none)", hasTxm ? 1 : 0);
    return hasTxm;
}

static BOOL jessi_is_ios26_or_later_core(void) {
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    return v.majorVersion >= 26;
}

static BOOL jessi_is_ios18_or_earlier_core(void) {
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    return v.majorVersion <= 18;
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

extern int dyld_get_active_platform(void);

static BOOL jessi_patch_macho_platform_for_slice(struct mach_header_64 *header) {
    if (!header) return NO;

    uint8_t *imageHeaderPtr = (uint8_t *)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    BOOL patched = NO;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_BUILD_VERSION) {
            struct build_version_command *buildver = (struct build_version_command *)command;
            int activePlatform = dyld_get_active_platform();
            if ((int)buildver->platform != activePlatform) {
                buildver->platform = (uint32_t)activePlatform;
                patched = YES;
            }
        } else if (command->cmd == LC_LOAD_DYLIB) {
            struct dylib_command *dylib = (struct dylib_command *)command;
            char *dylibName = (char *)((uint8_t *)dylib + dylib->dylib.name.offset);
            char *verPtr = dylibName ? strstr(dylibName, "/Versions/") : NULL;
            if (verPtr) {
                
                int lastComponentLen = (int)strlen(dylibName) - (int)(verPtr - dylibName) - 11;
                if (lastComponentLen >= 0) {
                    memmove(verPtr, verPtr + 11, (size_t)lastComponentLen);
                    verPtr[lastComponentLen] = '\0';
                    patched = YES;
                }
            }
        }
        command = (struct load_command *)((uint8_t *)command + command->cmdsize);
    }

    return patched;
}

static BOOL jessi_patch_macho_platform_for_file(const char *path) {
    if (!path || !path[0]) return NO;

    int fd = open(path, O_RDWR, (mode_t)0600);
    if (fd == -1) return NO;

    struct stat s;
    if (fstat(fd, &s) != 0 || s.st_size <= 0) {
        close(fd);
        return NO;
    }

    void *map = mmap(NULL, (size_t)s.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (!map || map == MAP_FAILED) {
        close(fd);
        return NO;
    }

    BOOL patched = NO;
    uint32_t magic = *(uint32_t *)map;
    if (magic == FAT_CIGAM) {
        struct fat_header *header = (struct fat_header *)map;
        struct fat_arch *arch = (struct fat_arch *)((uint8_t *)map + sizeof(struct fat_header));
        for (uint32_t i = 0; i < OSSwapInt32(header->nfat_arch); i++) {
            if (OSSwapInt32(arch->cputype) == CPU_TYPE_ARM64) {
                uint32_t off = OSSwapInt32(arch->offset);
                patched |= jessi_patch_macho_platform_for_slice((struct mach_header_64 *)((uint8_t *)map + off));
            }
            arch = (struct fat_arch *)((uint8_t *)arch + sizeof(struct fat_arch));
        }
    } else if (magic == MH_MAGIC_64) {
        struct mach_header_64 *mh = (struct mach_header_64 *)map;
        if (mh->cputype == CPU_TYPE_ARM64) {
            patched = jessi_patch_macho_platform_for_slice(mh);
        }
    }

    if (patched) {
        (void)msync(map, (size_t)s.st_size, MS_SYNC);
    }
    munmap(map, (size_t)s.st_size);
    close(fd);
    return patched;
}

static void jessi_for_each_dylib_under_dir(NSString *dir, void (^block)(NSString *fullPath)) {
    if (!dir.length || !block) return;

    NSURL *root = [NSURL fileURLWithPath:dir isDirectory:YES];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSURL *> *e = [fm enumeratorAtURL:root
                                includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                              errorHandler:^BOOL(__unused NSURL *url, __unused NSError *err) {
        return YES;
    }];

    for (NSURL *url in e) {
        NSNumber *isDir = nil;
        (void)[url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;

        NSString *path = url.path;
        if (![path.pathExtension.lowercaseString isEqualToString:@"dylib"]) continue;
        block(path);
    }
}

static void jessi_patch_jvm_dylibs_if_needed(NSString *javaHome) {
    if (!javaHome.length) return;
    if (!jessi_is_ios26_or_later_core()) return;

    
    if ([javaHome rangeOfString:@"/Library/Application Support/"].location == NSNotFound) return;

    NSArray<NSString *> *roots = @[
        [javaHome stringByAppendingPathComponent:@"lib"],
        [javaHome stringByAppendingPathComponent:@"lib/server"],
        [javaHome stringByAppendingPathComponent:@"lib/jli"],
    ];

    __block int patchedCount = 0;
    for (NSString *root in roots) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:root]) continue;
        jessi_for_each_dylib_under_dir(root, ^(NSString *fullPath) {
            BOOL did = jessi_patch_macho_platform_for_file(fullPath.fileSystemRepresentation);
            if (did) {
                patchedCount++;
                JESSI_TXM_LOG("[JESSI] Patched Mach-O platform for %s\n", fullPath.fileSystemRepresentation);
            }
        });
    }

    if (patchedCount > 0) {
        JESSI_TXM_LOG("[JESSI] Patched %d JVM dylib(s)\n", patchedCount);
    }
}

static BOOL jessi_dyld_bypass_ready = NO;
static void* jessi_hooked_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
static int jessi_hooked_fcntl(int fildes, int cmd, void *param);

static void *jessi_run_with_hw_breakpoints(void *(*fn)(void *), void *ctx);

typedef struct {
    const char *path;
    int flags;
} JessiDlopenCtx;

static void *jessi_dlopen_trampoline(void *ctx) {
    const JessiDlopenCtx *c = (const JessiDlopenCtx *)ctx;
    if (!c || !c->path) return NULL;
    return dlopen(c->path, c->flags);
}

static void jessi_preflight_dlopen_path(const char *label, const char *path) {
    if (!path || !path[0]) return;

    
    (void)dlerror();

    JessiDlopenCtx dlCtx = { .path = path, .flags = RTLD_GLOBAL | RTLD_NOW };
    void *h = jessi_run_with_hw_breakpoints(jessi_dlopen_trampoline, &dlCtx);
    if (!h) {
        const char *err = dlerror();
        JESSI_TXM_LOG("[JESSI] Preflight dlopen(%s) failed for %s: %s\n", label ? label : "?", path, err ? err : "unknown");
    } else {
        JESSI_TXM_LOG("[JESSI] Preflight dlopen(%s) OK: %s\n", label ? label : "?", path);
    }
}

static uint32_t jessi_read_file_magic32(const char *path, unsigned long long *outSize) {
    if (outSize) *outSize = 0;
    if (!path || !path[0]) return 0;

    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;

    struct stat st;
    if (fstat(fd, &st) == 0 && outSize) {
        *outSize = (unsigned long long)st.st_size;
    }

    uint32_t magic = 0;
    ssize_t n = read(fd, &magic, sizeof(magic));
    close(fd);
    if (n != (ssize_t)sizeof(magic)) return 0;
    return magic;
}

static BOOL jessi_magic_is_macho(uint32_t magicLE) {
    return magicLE == MH_MAGIC_64 || magicLE == FAT_MAGIC || magicLE == FAT_CIGAM;
}

static void jessi_preflight_jvm_dylibs_if_needed(NSString *javaHome) {
    if (!javaHome.length) return;
    if (!jessi_is_ios26_or_later_core()) return;
    if ([javaHome rangeOfString:@"/Library/Application Support/"].location == NSNotFound) return;
    if (!jessi_dyld_bypass_ready) {
        JESSI_TXM_LOG("[JESSI] Skipping preflight dlopen: dyld bypass not ready\n");
        return;
    }

    BOOL requiresTxm = jessi_device_requires_txm_workaround();

    NSString *libjimage = [javaHome stringByAppendingPathComponent:@"lib/libjimage.dylib"];
    NSString *libjvm = [javaHome stringByAppendingPathComponent:@"lib/server/libjvm.dylib"];
    NSString *libjava = [javaHome stringByAppendingPathComponent:@"lib/libjava.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:libjimage]) jessi_preflight_dlopen_path("libjimage", libjimage.fileSystemRepresentation);
    if (!requiresTxm) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:libjvm]) jessi_preflight_dlopen_path("libjvm", libjvm.fileSystemRepresentation);
    } else {
        JESSI_TXM_LOG("[JESSI] Skipping preflight dlopen(libjvm) on iOS 26 TXM\n");
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:libjava]) jessi_preflight_dlopen_path("libjava", libjava.fileSystemRepresentation);

    NSArray<NSString *> *roots = @[
        [javaHome stringByAppendingPathComponent:@"lib"],
        [javaHome stringByAppendingPathComponent:@"lib/server"],
        [javaHome stringByAppendingPathComponent:@"lib/jli"],
    ];

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    __block int preflightCount = 0;
    for (NSString *root in roots) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:root]) continue;
        jessi_for_each_dylib_under_dir(root, ^(NSString *fullPath) {
            if ([seen containsObject:fullPath]) return;
            [seen addObject:fullPath];
            preflightCount++;
            const char *label = fullPath.lastPathComponent.UTF8String;
            jessi_preflight_dlopen_path(label && label[0] ? label : "dylib", fullPath.fileSystemRepresentation);
        });
    }
    JESSI_TXM_LOG("[JESSI] Preflight dlopen complete (%d dylib(s))\n", preflightCount);
}

static mach_port_t jessi_exc_port = MACH_PORT_NULL;
static volatile uint64_t jessi_hw_redirect_orig[6] = {0};
static volatile uint64_t jessi_hw_redirect_target[6] = {0};

static void *jessi_exc_server_thread(void *unused) {
    (void)unused;
    if (jessi_exc_port == MACH_PORT_NULL) return NULL;

    JESSI_TXM_LOG("[JESSI] Mach exception server thread starting (port=%u)\n", jessi_exc_port);
    
    mach_msg_server(mach_exc_server,
                    sizeof(union __RequestUnion__mach_exc_subsystem),
                    jessi_exc_port,
                    MACH_MSG_OPTION_NONE);
    JESSI_TXM_LOG("[JESSI] Mach exception server thread exited\n");
    return NULL;
}

static void jessi_ensure_exc_server_started(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;

    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &jessi_exc_port);
    mach_port_insert_right(mach_task_self(), jessi_exc_port, jessi_exc_port, MACH_MSG_TYPE_MAKE_SEND);

    pthread_t thread;
    pthread_create(&thread, NULL, jessi_exc_server_thread, NULL);
    pthread_detach(thread);
}

static BOOL jessi_register_hw_redirect(uint64_t orig, uint64_t target) {
    if (!orig || !target) return NO;
    for (int i = 0; i < 6; i++) {
        if (jessi_hw_redirect_orig[i] == orig) return YES;
        if (jessi_hw_redirect_orig[i] == 0) {
            jessi_hw_redirect_orig[i] = orig;
            jessi_hw_redirect_target[i] = target;
            return YES;
        }
    }
    return NO;
}

static BOOL jessi_setup_hw_breakpoint_bypass(uint8_t *mmapSite, uint8_t *fcntlSite) {
    jessi_ensure_exc_server_started();
    BOOL any = NO;
    if (mmapSite) {
        any |= jessi_register_hw_redirect((uint64_t)mmapSite, (uint64_t)jessi_hooked_mmap);
        JESSI_TXM_LOG("[JESSI] Dyld bypass mmap breakpoint at %p\n", mmapSite);
    }
    if (fcntlSite) {
        any |= jessi_register_hw_redirect((uint64_t)fcntlSite, (uint64_t)jessi_hooked_fcntl);
        JESSI_TXM_LOG("[JESSI] Dyld bypass fcntl breakpoint at %p\n", fcntlSite);
    }
    if (!any) {
        JESSI_TXM_LOG("[JESSI] Dyld bypass could not register breakpoints (signatures not found)\n");
    }
    return any;
}

static void *jessi_run_with_hw_breakpoints(void *(*fn)(void *), void *ctx) {
    if (!fn) return NULL;

    
    if (jessi_hw_redirect_orig[0] == 0 || jessi_exc_port == MACH_PORT_NULL) {
        return fn(ctx);
    }

    JESSI_TXM_LOG("[JESSI] HW breakpoint trampoline enter (exc_port=%u)\n", jessi_exc_port);

    mach_port_t thread = mach_thread_self();

    
    arm_debug_state64_t origDebugState = {0};
    mach_msg_type_number_t origDebugCount = ARM_DEBUG_STATE64_COUNT;
    thread_get_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origDebugState, &origDebugCount);

    
    exception_mask_t masks[32];
    mach_msg_type_number_t masksCnt = 32;
    exception_handler_t handlers[32];
    exception_behavior_t behaviors[32];
    thread_state_flavor_t flavors[32];
    thread_get_exception_ports(thread, EXC_MASK_BREAKPOINT, masks, &masksCnt, handlers, behaviors, flavors);

    
    thread_set_exception_ports(thread, EXC_MASK_BREAKPOINT, jessi_exc_port,
                               EXCEPTION_STATE | MACH_EXCEPTION_CODES,
                               ARM_THREAD_STATE64);

    
    arm_debug_state64_t hookDebugState = {0};
    for (int i = 0; i < 6 && jessi_hw_redirect_orig[i]; i++) {
        hookDebugState.__bvr[i] = (uint64_t)jessi_hw_redirect_orig[i];
        
        hookDebugState.__bcr[i] = 0x1e5;
    }
    thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&hookDebugState, ARM_DEBUG_STATE64_COUNT);

    void *result = fn(ctx);

    
    thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origDebugState, ARM_DEBUG_STATE64_COUNT);

    
    for (mach_msg_type_number_t i = 0; i < masksCnt; i++) {
        thread_set_exception_ports(thread, masks[i], handlers[i], behaviors[i], flavors[i]);
        mach_port_deallocate(mach_task_self(), handlers[i]);
    }

    mach_port_deallocate(mach_task_self(), thread);

    JESSI_TXM_LOG("[JESSI] HW breakpoint trampoline exit\n");

    return result;
}

kern_return_t catch_mach_exception_raise(mach_port_t exception_port,
                                        mach_port_t thread,
                                        mach_port_t task,
                                        exception_type_t exception,
                                        mach_exception_data_t code,
                                        mach_msg_type_number_t codeCnt) {
    (void)exception_port; (void)thread; (void)task; (void)exception; (void)code; (void)codeCnt;
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise_state(mach_port_t exception_port,
                                              exception_type_t exception,
                                              const mach_exception_data_t code,
                                              mach_msg_type_number_t codeCnt,
                                              int *flavor,
                                              const thread_state_t old_state,
                                              mach_msg_type_number_t old_stateCnt,
                                              thread_state_t new_state,
                                              mach_msg_type_number_t *new_stateCnt) {
    (void)exception_port;
    (void)code;
    (void)codeCnt;

    if (!flavor || !old_state || !new_state || !new_stateCnt) return KERN_FAILURE;
    if (*flavor != ARM_THREAD_STATE64) return KERN_FAILURE;
    if (old_stateCnt < ARM_THREAD_STATE64_COUNT) return KERN_FAILURE;

    const arm_thread_state64_t *oldTS = (const arm_thread_state64_t *)old_state;
    arm_thread_state64_t *newTS = (arm_thread_state64_t *)new_state;
    *newTS = *oldTS;
    *new_stateCnt = old_stateCnt;

    if (exception != EXC_BREAKPOINT) return KERN_FAILURE;

    uint64_t pc = arm_thread_state64_get_pc(*newTS);
    JESSI_TXM_LOG("[JESSI] EXC_BREAKPOINT at pc=%p (codeCnt=%u)\n", (void *)pc, (unsigned)codeCnt);
    for (int i = 0; i < 6 && jessi_hw_redirect_orig[i]; i++) {
        if (pc == (uint64_t)jessi_hw_redirect_orig[i]) {
            JESSI_TXM_LOG("[JESSI] Redirecting breakpoint %d to %p\n", i, (void *)jessi_hw_redirect_target[i]);
            arm_thread_state64_set_pc_fptr(*newTS, (void *)jessi_hw_redirect_target[i]);
            return KERN_SUCCESS;
        }
    }
    JESSI_TXM_LOG("[JESSI] Breakpoint PC did not match registered targets\n");
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise_state_identity(mach_port_t exception_port,
                                                       mach_port_t thread,
                                                       mach_port_t task,
                                                       exception_type_t exception,
                                                       mach_exception_data_t code,
                                                       mach_msg_type_number_t codeCnt,
                                                       int *flavor,
                                                       thread_state_t old_state,
                                                       mach_msg_type_number_t old_stateCnt,
                                                       thread_state_t new_state,
                                                       mach_msg_type_number_t *new_stateCnt) {
    (void)thread;
    (void)task;
    return catch_mach_exception_raise_state(exception_port, exception, code, codeCnt,
                                           flavor, old_state, old_stateCnt, new_state, new_stateCnt);
}

static const uint8_t jessi_arm64_abs_branch_stub[24] = {
    0x88, 0x00, 0x00, 0x58, 
    0x00, 0x01, 0x1F, 0xD6, 
    0x1F, 0x20, 0x03, 0xD5, 
    0x1F, 0x20, 0x03, 0xD5, 
    0x41, 0x41, 0x41, 0x41, 
    0x41, 0x41, 0x41, 0x41  
};

static const uint8_t jessi_dyld_mmap_sig[]  = {0xB0, 0x18, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};
static const uint8_t jessi_dyld_fcntl_sig[] = {0x90, 0x0B, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};

extern void* __mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
extern int __fcntl(int fildes, int cmd, void* param);

static void *jessi_dyld_base(void) {
    struct task_dyld_info dyldInfo;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count);
    if (kr != KERN_SUCCESS) return NULL;

    struct dyld_all_image_infos *infos = (struct dyld_all_image_infos *)dyldInfo.all_image_info_addr;
    if (!infos) return NULL;
    return (void *)infos->dyldImageLoadAddress;
}

static bool jessi_write_abs_branch_stub(void *patchAddr, void *target) {
    if (!patchAddr || !target) return false;

    
    vm_address_t page = (vm_address_t)patchAddr & ~((vm_address_t)getpagesize() - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, (vm_size_t)getpagesize(), false,
                                 VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return false;

    memcpy(patchAddr, jessi_arm64_abs_branch_stub, sizeof(jessi_arm64_abs_branch_stub));
    *(void **)((uint8_t *)patchAddr + 16) = target;
    sys_icache_invalidate(patchAddr, sizeof(jessi_arm64_abs_branch_stub));

    
    kr = vm_protect(mach_task_self(), page, (vm_size_t)getpagesize(), false, VM_PROT_READ | VM_PROT_EXECUTE);
    return kr == KERN_SUCCESS;
}

static void jessi_builtin_memcpy(char *target, const char *source, size_t size) {
    for (size_t i = 0; i < size; i++) {
        target[i] = source[i];
    }
}

static bool jessi_write_abs_branch_stub_mirrored(void *patchAddr, void *target) {
    if (!patchAddr || !target) return false;

    JESSI_TXM_LOG("[JESSI] Mirrored patch start addr=%p target=%p\n", patchAddr, target);

    if (jessi_device_requires_txm_workaround()) {
        JESSI_TXM_LOG("[JESSI] JIT26 prepare region for patching addr=%p size=%zu\n", patchAddr, sizeof(jessi_arm64_abs_branch_stub));
        jessi_jit26_prepare_region_for_patching(patchAddr, sizeof(jessi_arm64_abs_branch_stub));
        JESSI_TXM_LOG("[JESSI] JIT26 prepare region for patching done\n");
    }

    vm_address_t mirrored = 0;
    vm_prot_t curProt = 0, maxProt = 0;
    kern_return_t ret = vm_remap(mach_task_self(), &mirrored, sizeof(jessi_arm64_abs_branch_stub), 0,
                                 VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)patchAddr, false,
                                 &curProt, &maxProt, VM_INHERIT_SHARE);
    if (ret != KERN_SUCCESS) {
        JESSI_TXM_LOG("[JESSI] Mirrored patch vm_remap failed ret=%d\n", ret);
        return false;
    }

    mirrored += (vm_address_t)patchAddr & PAGE_MASK;
    JESSI_TXM_LOG("[JESSI] Mirrored patch vm_remap ok mirrored=%p curProt=0x%x maxProt=0x%x\n", (void *)mirrored, curProt, maxProt);

    (void)vm_protect(mach_task_self(), mirrored, sizeof(jessi_arm64_abs_branch_stub), NO, VM_PROT_READ | VM_PROT_WRITE);

    jessi_builtin_memcpy((char *)mirrored, (const char *)jessi_arm64_abs_branch_stub, sizeof(jessi_arm64_abs_branch_stub));
    *(void **)((char *)mirrored + 16) = target;
    sys_icache_invalidate(patchAddr, sizeof(jessi_arm64_abs_branch_stub));

    JESSI_TXM_LOG("[JESSI] Mirrored patch complete (wrote to mirror=%p, original=%p)\n", (void *)mirrored, patchAddr);

    vm_deallocate(mach_task_self(), mirrored, sizeof(jessi_arm64_abs_branch_stub));
    return true;
}

static uint8_t *jessi_find_signature(uint8_t *base, const uint8_t *sig, size_t sigLen) {
    if (!base || !sig || sigLen == 0) return NULL;
    for (size_t off = 0; off + sigLen < 0x80000; off += 4) {
        if (base[off] == sig[0] && memcmp(base + off, sig, sigLen) == 0) {
            return base + off;
        }
    }
    return NULL;
}

static void* jessi_hooked_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    static int s_mmap_calls = 0;
    s_mmap_calls++;
    if (s_mmap_calls <= 20 || (s_mmap_calls % 100 == 0)) {
        JESSI_TXM_LOG("[JESSI] hooked_mmap call=%d addr=%p len=%zu prot=0x%x flags=0x%x fd=%d off=%lld\n",
                s_mmap_calls, addr, len, prot, flags, fd, (long long)offset);
    }
    
    if (flags & MAP_JIT) {
        errno = EINVAL;
        if (s_mmap_calls <= 20 || (s_mmap_calls % 100 == 0)) {
            JESSI_TXM_LOG("[JESSI] hooked_mmap rejected MAP_JIT\n");
        }
        return MAP_FAILED;
    }

    static int s_requiresTxm = -1;
    if (s_requiresTxm < 0) {
        s_requiresTxm = jessi_device_requires_txm_workaround() ? 1 : 0;
        if (s_requiresTxm) {
            JESSI_TXM_LOG("[JESSI] TXM device detected; using JIT26 prepare region in hooked_mmap\n");
        }
    }

    void *map = __mmap(addr, len, prot, flags, fd, offset);
    if (map == MAP_FAILED && fd > 0 && (prot & PROT_EXEC)) {
        if (s_mmap_calls <= 20 || (s_mmap_calls % 100 == 0)) {
            JESSI_TXM_LOG("[JESSI] hooked_mmap __mmap failed errno=%d, trying anon fallback\n", errno);
        }
        map = __mmap(addr, len, prot, flags | MAP_PRIVATE | MAP_ANON, 0, 0);
        if (map != MAP_FAILED) {
            if (s_requiresTxm) {
                if (s_mmap_calls <= 20 || (s_mmap_calls % 100 == 0)) {
                    JESSI_TXM_LOG("[JESSI] hooked_mmap TXM prepare anon map=%p len=%zu\n", map, len);
                }
                if (!jessi_jit26_prepare_region_chunked(map, len)) {
                    JESSI_TXM_LOG("[JESSI] hooked_mmap TXM prepare FAILED (debugger detached?)\n");
                    munmap(map, len);
                    errno = EPERM;
                    return MAP_FAILED;
                }
                if (s_mmap_calls <= 20 || (s_mmap_calls % 100 == 0)) {
                    JESSI_TXM_LOG("[JESSI] hooked_mmap TXM prepare done\n");
                }
            }

            vm_address_t mirrored = 0;
            vm_prot_t curProt = 0, maxProt = 0;
            kern_return_t ret = vm_remap(mach_task_self(), &mirrored, (vm_size_t)len, 0, VM_FLAGS_ANYWHERE,
                                         mach_task_self(), (vm_address_t)map, false, &curProt, &maxProt, VM_INHERIT_SHARE);
            if (s_mmap_calls <= 20 || (s_mmap_calls % 100 == 0)) {
                JESSI_TXM_LOG("[JESSI] hooked_mmap vm_remap ret=%d mirrored=%p\n", ret, (void *)mirrored);
            }
            if (ret != KERN_SUCCESS) {
                JESSI_TXM_LOG("[JESSI] hooked_mmap ERROR: vm_remap failed ret=%d (fd=%d off=%lld len=%zu)\n", ret, fd, (long long)offset, len);
                munmap(map, len);
                errno = EPERM;
                return MAP_FAILED;
            }

            kern_return_t protRet = vm_protect(mach_task_self(), mirrored, (vm_size_t)len, NO, VM_PROT_READ | VM_PROT_WRITE);
            if (protRet != KERN_SUCCESS) {
                JESSI_TXM_LOG("[JESSI] hooked_mmap ERROR: vm_protect(mirrored,RW) failed ret=%d (curProt=0x%x maxProt=0x%x)\n", protRet, curProt, maxProt);
                vm_deallocate(mach_task_self(), mirrored, (vm_size_t)len);
                munmap(map, len);
                errno = EPERM;
                return MAP_FAILED;
            }

            BOOL copied = NO;
            void *fileMap = __mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, offset);
            if (fileMap != MAP_FAILED) {
                memcpy((void *)mirrored, fileMap, len);
                munmap(fileMap, len);
                copied = YES;
            } else {
                uint8_t *dst = (uint8_t *)mirrored;
                size_t total = 0;
                while (total < len) {
                    ssize_t n = pread(fd, dst + total, len - total, offset + (off_t)total);
                    if (n <= 0) break;
                    total += (size_t)n;
                }
                if (total > 0) {
                    if (total < len) {
                        memset(dst + total, 0, len - total);
                    }
                    copied = YES;
                }
                if (!copied) {
                    JESSI_TXM_LOG("[JESSI] hooked_mmap ERROR: failed to source bytes (mmap+pread) fd=%d off=%lld len=%zu errno=%d\n", fd, (long long)offset, len, errno);
                }
            }

            vm_deallocate(mach_task_self(), mirrored, (vm_size_t)len);

            if (!copied) {
                munmap(map, len);
                errno = EPERM;
                return MAP_FAILED;
            }

            if (offset == 0 && len >= sizeof(uint32_t)) {
                uint32_t magic = *(volatile uint32_t *)map;
                if (magic != MH_MAGIC && magic != MH_MAGIC_64 && magic != FAT_MAGIC && magic != FAT_CIGAM && magic != FAT_MAGIC_64 && magic != FAT_CIGAM_64) {
                    JESSI_TXM_LOG("[JESSI] hooked_mmap WARNING: unexpected mapped magic=0x%08x (fd=%d len=%zu)\n", magic, fd, len);
                }
            }
        }
    }
    return map;
}

static int jessi_hooked_fcntl(int fildes, int cmd, void *param) {
    static int s_fcntl_calls = 0;
    s_fcntl_calls++;
    if (s_fcntl_calls <= 20 || (s_fcntl_calls % 100 == 0)) {
        JESSI_TXM_LOG("[JESSI] hooked_fcntl call=%d fd=%d cmd=%d\n", s_fcntl_calls, fildes, cmd);
    }
#ifndef F_ADDFILESIGS_RETURN
#define F_ADDFILESIGS_RETURN 97
#endif
#ifndef F_CHECK_LV
#define F_CHECK_LV 98
#endif

    if (cmd == F_CHECK_LV) {
        
        return 0;
    }

    if (cmd == F_ADDFILESIGS_RETURN) {
        if (param) {
#ifdef __APPLE__
            if (sizeof(fsignatures_t) >= sizeof(uint32_t)) {
                ((fsignatures_t *)param)->fs_file_start = 0xFFFFFFFFu;
            } else {
                typedef struct {
                    uint32_t fs_file_start;
                } jessi_fsignatures_prefix_t;
                ((jessi_fsignatures_prefix_t *)param)->fs_file_start = 0xFFFFFFFFu;
            }
#else
            typedef struct {
                uint32_t fs_file_start;
            } jessi_fsignatures_prefix_t;
            ((jessi_fsignatures_prefix_t *)param)->fs_file_start = 0xFFFFFFFFu;
#endif
        }
        return 0;
    }

    return __fcntl(fildes, cmd, param);
}

static void jessi_init_dyld_validation_bypass_if_needed(void) {
    static BOOL didInit = NO;
    if (didInit) return;
    didInit = YES;

    BOOL ios26OrLater = jessi_is_ios26_or_later_core();
    BOOL ios18OrEarlier = jessi_is_ios18_or_earlier_core();
    JESSI_TXM_LOG("[JESSI] Dyld bypass init (ios26=%d ios18OrEarlier=%d)\n", ios26OrLater ? 1 : 0, ios18OrEarlier ? 1 : 0);
    if (!ios18OrEarlier && !ios26OrLater) {
        return;
    }

    if (!jessi_check_jit_enabled() && !ios26OrLater) {
        JESSI_TXM_LOG("[JESSI] Dyld bypass skipped (JIT not enabled)\n");
        return;
    }

    void *dyld = jessi_dyld_base();
    if (!dyld) {
        JESSI_TXM_LOG("[JESSI] Dyld bypass failed (no dyld base)\n");
        return;
    }

    uint8_t *base = (uint8_t *)dyld;
    uint8_t *mmapSite = jessi_find_signature(base, jessi_dyld_mmap_sig, sizeof(jessi_dyld_mmap_sig));
    uint8_t *fcntlSite = jessi_find_signature(base, jessi_dyld_fcntl_sig, sizeof(jessi_dyld_fcntl_sig));
    JESSI_TXM_LOG("[JESSI] dyld base=%p mmapSig=%p fcntlSig=%p\n", base, mmapSite, fcntlSite);

    if (ios18OrEarlier) {
        
        signal(SIGBUS, SIG_IGN);

        bool ok1 = false, ok2 = false;
        if (mmapSite) {
            ok1 = jessi_write_abs_branch_stub(mmapSite, (void *)jessi_hooked_mmap);
            JESSI_TXM_LOG("[JESSI] Dyld bypass mmap %s at %p\n", ok1 ? "hooked" : "failed", mmapSite);
        }
        if (fcntlSite) {
            ok2 = jessi_write_abs_branch_stub(fcntlSite, (void *)jessi_hooked_fcntl);
            JESSI_TXM_LOG("[JESSI] Dyld bypass fcntl %s at %p\n", ok2 ? "hooked" : "failed", fcntlSite);
        }
        if (!(ok1 || ok2)) {
            JESSI_TXM_LOG("[JESSI] Dyld bypass did not hook any targets\n");
        }
        jessi_dyld_bypass_ready = (ok1 || ok2) ? YES : NO;
        return;
    }

    if (ios26OrLater) {
        BOOL txmSupport = [JessiSettings shared].txmSupport;
        if (!txmSupport) {
            JESSI_TXM_LOG("[JESSI] TXM Support disabled in settings; skipping iOS 26 dyld/JIT bypass init.\n");
            return;
        }
        BOOL requiresTxm = jessi_device_requires_txm_workaround();
        if (requiresTxm) {
            JESSI_TXM_LOG("[JESSI] iOS 26 TXM device: verifying debugger and sending extension script\n");
            jessi_install_sigtrap_fallback_if_needed();
            void *legacyResult = jessi_jit26_create_region_legacy((size_t)getpagesize());
            JESSI_TXM_LOG("[JESSI] Legacy JIT probe result=%p\n", legacyResult);
            if ((uint32_t)(uintptr_t)legacyResult != 0x690000E0u) {
                if (legacyResult != NULL && legacyResult != MAP_FAILED) {
                    munmap(legacyResult, (size_t)getpagesize());
                }
                JESSI_TXM_LOG("[JESSI] ERROR: StikDebug is using a legacy script. Universal JIT script required.\n");
                jessi_dyld_bypass_ready = NO;
                return;
            }

            if (!jessi_send_jit26_extension_script()) {
                JESSI_TXM_LOG("[JESSI] ERROR: Failed to send JIT26 extension script\n");
                jessi_dyld_bypass_ready = NO;
                return;
            }

            jessi_jit26_set_detach_after_first_br(NO);
            JESSI_TXM_LOG("[JESSI] Set debugger to stay attached\n");

            task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);

            JESSI_TXM_LOG("[JESSI] iOS 26 TXM: starting mirrored dyld patching\n");

            signal(SIGBUS, SIG_IGN);

            bool ok1 = false, ok2 = false;
            if (mmapSite) {
                JESSI_TXM_LOG("[JESSI] Mirrored patching dyld mmap at %p\n", mmapSite);
                ok1 = jessi_write_abs_branch_stub_mirrored(mmapSite, (void *)jessi_hooked_mmap);
                JESSI_TXM_LOG("[JESSI] Dyld bypass mmap mirrored %s at %p\n", ok1 ? "ok" : "failed", mmapSite);
            }
            if (fcntlSite) {
                JESSI_TXM_LOG("[JESSI] Mirrored patching dyld fcntl at %p\n", fcntlSite);
                ok2 = jessi_write_abs_branch_stub_mirrored(fcntlSite, (void *)jessi_hooked_fcntl);
                JESSI_TXM_LOG("[JESSI] Dyld bypass fcntl mirrored %s at %p\n", ok2 ? "ok" : "failed", fcntlSite);
            }

            signal(SIGBUS, SIG_DFL);

            jessi_dyld_bypass_ready = (ok1 || ok2) ? YES : NO;
            if (!jessi_dyld_bypass_ready) {
                JESSI_TXM_LOG("[JESSI] Mirrored patching failed completely; dyld bypass unavailable\n");
            }
            return;
        }

        JESSI_TXM_LOG("[JESSI] iOS 26 non-TXM device: using HW breakpoints\n");
        jessi_dyld_bypass_ready = jessi_setup_hw_breakpoint_bypass(mmapSite, fcntlSite);
    }
}

typedef struct {
    JLI_Launch_func *fn;
    int argc;
    const char **argv;
    int jargc;
    const char **jargv;
    const char *jfullversion;
    const char *jdotversion;
    const char *progname;
    const char *launchername;
    jint result;
} JessiJliLaunchCtx;

static void *jessi_jli_launch_trampoline(void *ctx) {
    JessiJliLaunchCtx *c = (JessiJliLaunchCtx *)ctx;
    if (!c || !c->fn) return NULL;
    c->result = c->fn(c->jargc, c->jargv,
                      0, NULL,
                      0, NULL,
                      c->jfullversion,
                      c->jdotversion,
                      c->progname,
                      c->launchername,
                      JNI_FALSE,
                      JNI_TRUE,
                      JNI_FALSE,
                      JNI_TRUE);
    return NULL;
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
    NSString *bundleRoot = [[NSBundle mainBundle] bundlePath];

    NSString *versioned = [bundleRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"java%@", javaVersion]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:versioned]) return versioned;

    NSString *generic = [bundleRoot stringByAppendingPathComponent:@"java"]; 
    if ([[NSFileManager defaultManager] fileExistsAtPath:generic]) return generic;

    
    NSURL *appSupport = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask] firstObject];
    NSString *runtimesRoot = [[appSupport URLByAppendingPathComponent:@"Runtimes" isDirectory:YES] path];
    if (runtimesRoot.length) {
        NSString *installed = [runtimesRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"jre%@", javaVersion]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:installed]) return installed;
    }

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

            NSString *javaHome = bundleJavaHomeForVersion([NSString stringWithUTF8String:javaVersionC]);
            if (!javaHome) {
                fprintf(stderr, "Error: bundled Java runtime not found (java/ or java<ver>/)\n");
                return 3;
            }

            [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:workingDirC] withIntermediateDirectories:YES attributes:nil error:nil];

            NSString *workingDir = [NSString stringWithUTF8String:workingDirC];
            NSString *stdioLog = [workingDir stringByAppendingPathComponent:@"jessi-stdio.log"]; 
            redirect_stdio_to(stdioLog);

            BOOL isPaperServer = NO;
            @try {
                NSString *cfgPath = [workingDir stringByAppendingPathComponent:@"jessiserverconfig.json"]; 
                NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath options:0 error:nil];
                if (cfgData.length) {
                    id obj = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
                    if ([obj isKindOfClass:[NSDictionary class]]) {
                        id software = ((NSDictionary *)obj)[@"software"];
                        if ([software isKindOfClass:[NSString class]]) {
                            NSString *sw = [(NSString *)software lowercaseString];
                            if ([sw isEqualToString:@"paper"]) {
                                isPaperServer = YES;
                            }
                        }
                    }
                }
            } @catch (__unused NSException *e) {
                isPaperServer = NO;
            }

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

            jessi_patch_jvm_dylibs_if_needed(javaHome);

            
            jessi_init_dyld_validation_bypass_if_needed();
            jessi_preflight_jvm_dylibs_if_needed(javaHome);

            if (jessi_is_ios26_or_later_core() &&
                [javaHome rangeOfString:@"/Library/Application Support/"].location != NSNotFound &&
                !jessi_dyld_bypass_ready) {
                JESSI_TXM_LOG("[JESSI] Error: dyld bypass is not active for Application Support runtime on iOS 26; library validation will block dlopen.\n");
                return 6;
            }

            JESSI_TXM_LOG("[JESSI] Loading libjli from %s\n", libjliPath.fileSystemRepresentation);

            if ([javaHome rangeOfString:@"/Library/Application Support/"].location != NSNotFound) {
                unsigned long long sz = 0;
                uint32_t m = jessi_read_file_magic32(libjliPath.fileSystemRepresentation, &sz);
                JESSI_TXM_LOG("[JESSI] libjli on-disk size=%llu magic=0x%08x\n", sz, m);
                if (!jessi_magic_is_macho(m)) {
                    JESSI_TXM_LOG("[JESSI] Error: installed JVM runtime appears corrupted (libjli is not Mach-O). Delete and reinstall the JVM in Settings.\n");
                    return 7;
                }
            }

            JessiDlopenCtx dlCtx = { .path = libjliPath.fileSystemRepresentation, .flags = RTLD_GLOBAL | RTLD_NOW };
            void *libjli = jessi_run_with_hw_breakpoints(jessi_dlopen_trampoline, &dlCtx);
            if (!libjli) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlopen(libjli) failed: %s\n", err ? err : "unknown");
                JESSI_TXM_LOG("[JESSI] Hint: iOS enforces code signing/library validation for Mach-O dylibs.\n");
                JESSI_TXM_LOG("[JESSI] If this JVM was downloaded into Application Support, it may need to be installed/signed via TrollStore with appropriate entitlements (e.g. disable library validation).\n");
                return 4;
            }

            JLI_Launch_func *JLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
            if (!JLI_Launch) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlsym(JLI_Launch) failed: %s\n", err ? err : "unknown");
                return 5;
            }
            JESSI_TXM_LOG("[JESSI] JLI_Launch resolved at %p\n", (void *)JLI_Launch);

            NSString *javaPath = [javaHome stringByAppendingPathComponent:@"bin/java"]; 
            NSString *userDirArg = [@"-Duser.dir=" stringByAppendingString:workingDir];
            NSString *userHomeArg = [@"-Duser.home=" stringByAppendingString:workingDir];
            NSString *javaHomeArg = [@"-Djava.home=" stringByAppendingString:javaHome];
            NSString *tmpArg = [@"-Djava.io.tmpdir=" stringByAppendingString:tmpDir];

            NSString *frameworks = [[NSBundle mainBundle] privateFrameworksPath];
            NSString *frameworksPath = frameworks ?: @"";
            NSString *libPathArg = frameworksPath.length ? [@"-Djava.library.path=" stringByAppendingString:frameworksPath] : nil;

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
            BOOL txmSupport = [JessiSettings shared].txmSupport;

            BOOL flagNettyNoNative = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagNettyNoNative"];
            BOOL flagJnaNoSys = [[NSUserDefaults standardUserDefaults] boolForKey:@"jessi.jvm.flagJnaNoSys"];

            const char *jargv[80];
            int idx = 0;
            jargv[idx++] = javaPath.UTF8String;
            jargv[idx++] = xmx.UTF8String;
            jargv[idx++] = xms.UTF8String;

            JESSI_TXM_LOG("[JESSI] Launching JVM (iOS%ld, Java %s)\n", (long)iosMajor, javaVersionC);

            
            if (ios26OrLater && txmSupport) {
                jargv[idx++] = "-XX:+UnlockExperimentalVMOptions";
                jargv[idx++] = "-XX:+DisablePrimordialThreadGuardPages";
            }
            
            if (ios26OrLater && txmSupport && isJava17Plus) {
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
            BOOL userSetPaperIgnoreJavaVersion = jessi_args_contain_prefix(extra, @"-DPaper.IgnoreJavaVersion");
            
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

            if (isPaperServer && !userSetPaperIgnoreJavaVersion) {
                jargv[idx++] = "-DPaper.IgnoreJavaVersion=true";
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

            JessiJliLaunchCtx launchCtx = {
                .fn = JLI_Launch,
                .jargc = jargc,
                .jargv = (const char **)jargv,
                .jfullversion = fullver,
                .jdotversion = dotver,
                .progname = "java",
                .launchername = "openjdk",
                .result = 0,
            };
            JESSI_TXM_LOG("[JESSI] Invoking JLI_Launch (server)\n");
            (void)jessi_run_with_hw_breakpoints(jessi_jli_launch_trampoline, &launchCtx);
            JESSI_TXM_LOG("[JESSI] JLI_Launch returned %d\n", (int)launchCtx.result);
            int exitCode = (int)launchCtx.result;
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

int jessi_spawn_tool(int argc, char *argv[]) {
    pid_t pid;
    NSString *executablePath = [[NSBundle mainBundle] executablePath];
    char *execPathC = strdup([executablePath fileSystemRepresentation]);
    
    char **spawnArgv = malloc((argc + 2) * sizeof(char *));
    spawnArgv[0] = execPathC;
    for (int i = 0; i < argc; i++) {
        spawnArgv[i + 1] = argv[i];
    }
    spawnArgv[argc + 1] = NULL;
    
    extern char **environ;
    int ret = posix_spawn(&pid, execPathC, NULL, NULL, spawnArgv, environ);
    
    int code = 0;
    if (ret == 0) {
        int status;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status)) {
            code = WEXITSTATUS(status);
        } else {
            code = 252;
        }
    } else {
        code = 253;
        fprintf(stderr, "Failed to spawn JVM process: %s\n", strerror(ret));
    }
    
    free(execPathC);
    free(spawnArgv);
    return code;
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

            jessi_patch_jvm_dylibs_if_needed(javaHome);

            jessi_init_dyld_validation_bypass_if_needed();

            jessi_preflight_jvm_dylibs_if_needed(javaHome);

            if (jessi_is_ios26_or_later_core() &&
                [javaHome rangeOfString:@"/Library/Application Support/"].location != NSNotFound &&
                !jessi_dyld_bypass_ready) {
                fprintf(stderr, "[JESSI] Error: dyld bypass is not active for Application Support runtime on iOS 26; library validation will block dlopen.\n");
                return 6;
            }

            JESSI_TXM_LOG("[JESSI] Loading libjli (tool) from %s\n", libjliPath.fileSystemRepresentation);

            JessiDlopenCtx dlCtx = { .path = libjliPath.fileSystemRepresentation, .flags = RTLD_GLOBAL | RTLD_NOW };
            void *libjli = jessi_run_with_hw_breakpoints(jessi_dlopen_trampoline, &dlCtx);
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
            JESSI_TXM_LOG("[JESSI] JLI_Launch (tool) resolved at %p\n", (void *)JLI_Launch);

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

            JessiJliLaunchCtx launchCtx = {
                .fn = JLI_Launch,
                .jargc = jargc,
                .jargv = (const char **)jargv,
                .jfullversion = fullver,
                .jdotversion = dotver,
                .progname = "java",
                .launchername = "openjdk",
                .result = 0,
            };
            JESSI_TXM_LOG("[JESSI] Invoking JLI_Launch (tool)\n");
            (void)jessi_run_with_hw_breakpoints(jessi_jli_launch_trampoline, &launchCtx);
            JESSI_TXM_LOG("[JESSI] JLI_Launch (tool) returned %d\n", (int)launchCtx.result);
            int exitCode = (int)launchCtx.result;
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
