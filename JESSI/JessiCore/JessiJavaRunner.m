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
#import "MachExc/mach_excServer.h"

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

__attribute__((noinline,optnone,naked))
static void *jessi_jit26_prepare_region(void *addr, size_t len) {
    __asm__(
        "mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret"
    );
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

__attribute__((noinline,optnone,naked))
static void jessi_jit26_prepare_region_for_patching(void *addr, size_t size) {
    __asm__(
        "mov x16, #4 \n"
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

static BOOL jessi_txm_skip_dyld_bypass = NO;

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
        fprintf(stderr, "[JESSI] Relying on external StikDebug handler for JIT.\n");
        BOOL hasHandler = jessi_task_has_breakpoint_exception_handler();
        fprintf(stderr, "[JESSI] TXM setup: CS_DEBUGGED=%d, hasBreakpointHandler=%d\n", jessi_is_cs_debugged() ? 1 : 0, hasHandler ? 1 : 0);
        if (!hasHandler) {
            fprintf(stderr, "[JESSI] TXM setup skipped (no breakpoint handler)\n");
            return;
        }

        didSetup = YES;
        fprintf(stderr, "[JESSI] TXM setup: external handler active, skipping dyld bypass (Amethyst-style)\n");
        jessi_txm_skip_dyld_bypass = YES;
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
                fprintf(stderr, "[JESSI] Patched Mach-O platform for %s\n", fullPath.fileSystemRepresentation);
            }
        });
    }

    if (patchedCount > 0) {
        fprintf(stderr, "[JESSI] Patched %d JVM dylib(s)\n", patchedCount);
    }
}

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
        fprintf(stderr, "[JESSI] Preflight dlopen(%s) failed for %s: %s\n", label ? label : "?", path, err ? err : "unknown");
    } else {
        fprintf(stderr, "[JESSI] Preflight dlopen(%s) OK: %s\n", label ? label : "?", path);
    }
}

static void jessi_preflight_jvm_dylibs_if_needed(NSString *javaHome) {
    if (!javaHome.length) return;
    if (!jessi_is_ios26_or_later_core()) return;
    if ([javaHome rangeOfString:@"/Library/Application Support/"].location == NSNotFound) return;

    
    
    NSString *libjimage = [javaHome stringByAppendingPathComponent:@"lib/libjimage.dylib"];
    NSString *libjvm = [javaHome stringByAppendingPathComponent:@"lib/server/libjvm.dylib"];
    NSString *libjava = [javaHome stringByAppendingPathComponent:@"lib/libjava.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:libjimage]) jessi_preflight_dlopen_path("libjimage", libjimage.fileSystemRepresentation);
    if ([[NSFileManager defaultManager] fileExistsAtPath:libjvm]) jessi_preflight_dlopen_path("libjvm", libjvm.fileSystemRepresentation);
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
    fprintf(stderr, "[JESSI] Preflight dlopen complete (%d dylib(s))\n", preflightCount);
}

static mach_port_t jessi_exc_port = MACH_PORT_NULL;
static volatile uint64_t jessi_hw_redirect_orig[6] = {0};
static volatile uint64_t jessi_hw_redirect_target[6] = {0};

static void *jessi_exc_server_thread(void *unused) {
    (void)unused;
    if (jessi_exc_port == MACH_PORT_NULL) return NULL;

    
    mach_msg_server(mach_exc_server,
                    sizeof(union __RequestUnion__catch_mach_exc_subsystem),
                    jessi_exc_port,
                    MACH_MSG_OPTION_NONE);
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

static void *jessi_run_with_hw_breakpoints(void *(*fn)(void *), void *ctx) {
    if (!fn) return NULL;

    
    if (jessi_hw_redirect_orig[0] == 0 || jessi_exc_port == MACH_PORT_NULL) {
        return fn(ctx);
    }

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
    for (int i = 0; i < 6 && jessi_hw_redirect_orig[i]; i++) {
        if (pc == (uint64_t)jessi_hw_redirect_orig[i]) {
            arm_thread_state64_set_pc_fptr(*newTS, (void *)jessi_hw_redirect_target[i]);
            return KERN_SUCCESS;
        }
    }
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

static bool jessi_write_abs_branch_stub_mirrored(void *patchAddr, void *target, BOOL prepareForPatching) {
    if (!patchAddr || !target) return false;

    if (prepareForPatching) {
        jessi_jit26_prepare_region_for_patching(patchAddr, sizeof(jessi_arm64_abs_branch_stub));
    }

    vm_address_t mirrored = 0;
    vm_prot_t curProt = 0, maxProt = 0;
    kern_return_t ret = vm_remap(mach_task_self(), &mirrored, (vm_size_t)sizeof(jessi_arm64_abs_branch_stub), 0, VM_FLAGS_ANYWHERE,
                                 mach_task_self(), (vm_address_t)patchAddr, false, &curProt, &maxProt, VM_INHERIT_SHARE);
    if (ret != KERN_SUCCESS) return false;

    mirrored += ((vm_address_t)patchAddr & PAGE_MASK);
    vm_protect(mach_task_self(), mirrored, (vm_size_t)sizeof(jessi_arm64_abs_branch_stub), NO, VM_PROT_READ | VM_PROT_WRITE);

    memcpy((void *)mirrored, jessi_arm64_abs_branch_stub, sizeof(jessi_arm64_abs_branch_stub));
    *(void **)((uint8_t *)mirrored + 16) = target;
    sys_icache_invalidate(patchAddr, sizeof(jessi_arm64_abs_branch_stub));

    vm_deallocate(mach_task_self(), mirrored, (vm_size_t)sizeof(jessi_arm64_abs_branch_stub));
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
    
    if (flags & MAP_JIT) {
        errno = EINVAL;
        return MAP_FAILED;
    }

    void *map = __mmap(addr, len, prot, flags, fd, offset);
    if (map == MAP_FAILED && fd > 0 && (prot & PROT_EXEC)) {
        
        
        map = __mmap(addr, len, prot, (flags | MAP_PRIVATE | MAP_ANON), 0, 0);
        if (map != MAP_FAILED) {
            if (jessi_txm_jit26_ready && jessi_is_ios26_or_later_core() && jessi_device_requires_txm_workaround() && [JessiSettings shared].iOS26JITSupport) {
                (void)jessi_jit26_prepare_region(map, len);
            }
            void *fileMap = __mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, offset);
            if (fileMap != MAP_FAILED) {
                vm_address_t mirrored = 0;
                vm_prot_t curProt = 0, maxProt = 0;
                kern_return_t ret = vm_remap(mach_task_self(), &mirrored, (vm_size_t)len, 0, VM_FLAGS_ANYWHERE,
                                             mach_task_self(), (vm_address_t)map, false, &curProt, &maxProt, VM_INHERIT_SHARE);
                if (ret == KERN_SUCCESS) {
                    mirrored += ((vm_address_t)map & PAGE_MASK);
                    vm_protect(mach_task_self(), mirrored, (vm_size_t)len, NO, VM_PROT_READ | VM_PROT_WRITE);
                    memcpy((void *)mirrored, fileMap, len);
                    vm_deallocate(mach_task_self(), mirrored, (vm_size_t)len);
                }
                munmap(fileMap, len);
            }
        }
    }
    return map;
}

static int jessi_hooked_fcntl(int fildes, int cmd, void *param) {
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
        
        
        (void)__fcntl(fildes, cmd, param);
        if (param) {
            
            
            typedef struct {
                uint32_t fs_file_start;
            } jessi_fsignatures_prefix_t;
            ((jessi_fsignatures_prefix_t *)param)->fs_file_start = 0xFFFFFFFFu;
        }
        return 0;
    }

    return __fcntl(fildes, cmd, param);
}

static void jessi_init_dyld_validation_bypass_if_needed(void) {
    static BOOL didInit = NO;
    if (didInit) return;

    BOOL ios26OrLater = jessi_is_ios26_or_later_core();
    BOOL ios18OrEarlier = jessi_is_ios18_or_earlier_core();
    if (!ios18OrEarlier && !ios26OrLater) {
        return;
    }

    if (jessi_txm_skip_dyld_bypass) {
        fprintf(stderr, "[JESSI] Dyld bypass skipped (TXM with external handler)\n");
        didInit = YES;
        return;
    }

    didInit = YES;

    BOOL txmEnabled = ios26OrLater && jessi_txm_jit26_ready && jessi_device_requires_txm_workaround() && [JessiSettings shared].iOS26JITSupport;

    if (!jessi_check_jit_enabled() && !ios26OrLater) {
        fprintf(stderr, "[JESSI] Dyld bypass skipped (JIT not enabled)\n");
        return;
    }

    void *dyld = jessi_dyld_base();
    if (!dyld) {
        fprintf(stderr, "[JESSI] Dyld bypass failed (no dyld base)\n");
        return;
    }

    uint8_t *base = (uint8_t *)dyld;
    uint8_t *mmapSite = jessi_find_signature(base, jessi_dyld_mmap_sig, sizeof(jessi_dyld_mmap_sig));
    uint8_t *fcntlSite = jessi_find_signature(base, jessi_dyld_fcntl_sig, sizeof(jessi_dyld_fcntl_sig));

    if (ios18OrEarlier) {
        
        signal(SIGBUS, SIG_IGN);

        bool ok1 = false, ok2 = false;
        if (mmapSite) {
            ok1 = jessi_write_abs_branch_stub(mmapSite, (void *)jessi_hooked_mmap);
            fprintf(stderr, "[JESSI] Dyld bypass mmap %s at %p\n", ok1 ? "hooked" : "failed", mmapSite);
        }
        if (fcntlSite) {
            ok2 = jessi_write_abs_branch_stub(fcntlSite, (void *)jessi_hooked_fcntl);
            fprintf(stderr, "[JESSI] Dyld bypass fcntl %s at %p\n", ok2 ? "hooked" : "failed", fcntlSite);
        }
        if (!(ok1 || ok2)) {
            fprintf(stderr, "[JESSI] Dyld bypass did not hook any targets\n");
        }
        return;
    }

    if (ios26OrLater) {
        if (txmEnabled) {
            signal(SIGBUS, SIG_IGN);

            bool ok1 = false, ok2 = false;
            if (mmapSite) {
                ok1 = jessi_write_abs_branch_stub_mirrored(mmapSite, (void *)jessi_hooked_mmap, YES);
                fprintf(stderr, "[JESSI] Dyld bypass mmap %s at %p (TXM mirrored)\n", ok1 ? "hooked" : "failed", mmapSite);
            }
            if (fcntlSite) {
                ok2 = jessi_write_abs_branch_stub_mirrored(fcntlSite, (void *)jessi_hooked_fcntl, YES);
                fprintf(stderr, "[JESSI] Dyld bypass fcntl %s at %p (TXM mirrored)\n", ok2 ? "hooked" : "failed", fcntlSite);
            }
            if (!(ok1 || ok2)) {
                fprintf(stderr, "[JESSI] Dyld bypass did not hook any targets (TXM)\n");
            }
            return;
        }

        jessi_ensure_exc_server_started();
        BOOL any = NO;
        if (mmapSite) {
            any |= jessi_register_hw_redirect((uint64_t)mmapSite, (uint64_t)jessi_hooked_mmap);
            fprintf(stderr, "[JESSI] Dyld bypass mmap breakpoint at %p\n", mmapSite);
        }
        if (fcntlSite) {
            any |= jessi_register_hw_redirect((uint64_t)fcntlSite, (uint64_t)jessi_hooked_fcntl);
            fprintf(stderr, "[JESSI] Dyld bypass fcntl breakpoint at %p\n", fcntlSite);
        }
        if (!any) {
            fprintf(stderr, "[JESSI] Dyld bypass could not register breakpoints (signatures not found)\n");
        }
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
            jessi_ios26_txm_setup_if_needed(workingDir);

            NSString *libjliPath8 = [javaHome stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
            NSString *libjliPath11 = [javaHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
            NSString *libjliPath = [[NSFileManager defaultManager] fileExistsAtPath:libjliPath8] ? libjliPath8 : libjliPath11;

            jessi_patch_jvm_dylibs_if_needed(javaHome);

            
            jessi_init_dyld_validation_bypass_if_needed();
            jessi_preflight_jvm_dylibs_if_needed(javaHome);

            JessiDlopenCtx dlCtx = { .path = libjliPath.fileSystemRepresentation, .flags = RTLD_GLOBAL | RTLD_NOW };
            void *libjli = jessi_run_with_hw_breakpoints(jessi_dlopen_trampoline, &dlCtx);
            if (!libjli) {
                const char *err = dlerror();
                fprintf(stderr, "Error: dlopen(libjli) failed: %s\n", err ? err : "unknown");
                fprintf(stderr, "[JESSI] Hint: iOS enforces code signing/library validation for Mach-O dylibs.\n");
                fprintf(stderr, "[JESSI] If this JVM was downloaded into Application Support, it may need to be installed/signed via TrollStore with appropriate entitlements (e.g. disable library validation).\n");
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
            (void)jessi_run_with_hw_breakpoints(jessi_jli_launch_trampoline, &launchCtx);
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

            jessi_ios26_txm_setup_if_needed(workingDir);

            NSString *libjliPath8 = [javaHome stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
            NSString *libjliPath11 = [javaHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
            NSString *libjliPath = [[NSFileManager defaultManager] fileExistsAtPath:libjliPath8] ? libjliPath8 : libjliPath11;

            jessi_patch_jvm_dylibs_if_needed(javaHome);

            jessi_init_dyld_validation_bypass_if_needed();

            jessi_preflight_jvm_dylibs_if_needed(javaHome);

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
            (void)jessi_run_with_hw_breakpoints(jessi_jli_launch_trampoline, &launchCtx);
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
