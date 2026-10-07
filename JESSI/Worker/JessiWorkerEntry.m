#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>

kern_return_t jessi_worker_vm_protect(mach_port_name_t task, mach_vm_address_t address, mach_vm_size_t size, boolean_t setMax, vm_prot_t newProt);
__asm__(
    ".text\n"
    ".global _jessi_worker_vm_protect\n"
    "_jessi_worker_vm_protect:\n"
    "    mov x16, #-0xe\n"
    "    svc #0x80\n"
    "    ret\n"
);

static uint64_t emulate_adrp(uint32_t instruction, uint64_t pc) {
    if ((instruction & 0x9F000000) != 0x90000000) return 0;
    int32_t immHiLo = (instruction & 0xFFFFE0) >> 3;
    immHiLo |= (instruction & 0x60000000) >> 29;
    if (instruction & 0x800000) immHiLo |= 0xFFE00000;
    return (pc & ~0xFFFULL) + ((int64_t)immHiLo << 12);
}

static uint64_t emulate_adrp_ldr(uint32_t adrp, uint32_t ldr, uint64_t pc) {
    uint64_t target = emulate_adrp(adrp, pc);
    if (!target) return 0;
    if ((adrp & 0x1F) != ((ldr >> 5) & 0x1F)) return 0;
    if ((ldr & 0xFFC00000) != 0xF9400000) return 0;
    return target + (((ldr >> 10) & 0xFFF) << 3);
}

typedef bool (*tpro_supported_fn)(void);
typedef void (*tpro_restrict_fn)(void);

static void set_tpro_writable(BOOL writable) {
    static tpro_supported_fn supported;
    static tpro_restrict_fn toRW, toRO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = (tpro_supported_fn)dlsym(RTLD_DEFAULT, "os_tpro_is_supported");
        toRW = (tpro_restrict_fn)dlsym(RTLD_DEFAULT, "os_thread_self_restrict_tpro_to_rw");
        toRO = (tpro_restrict_fn)dlsym(RTLD_DEFAULT, "os_thread_self_restrict_tpro_to_ro");
    });
    if (!supported || !supported()) return;
    if (writable && toRW) toRW();
    if (!writable && toRO) toRO();
}

static BOOL hook_dyld_api(const char *functionName, uint32_t adrpOffset, void **original, void *replacement) {
    uint32_t *base = dlsym(RTLD_DEFAULT, functionName);
    if (!base) return NO;
    uint32_t *adrpPtr = base + adrpOffset;

    long extra = -1;
    for (uint32_t *cur = adrpPtr; cur < base + 200; cur++) {
        if ((cur[0] & 0x9F000000) != 0x90000000) continue;
        if ((cur[1] & 0xFFC00000) != 0xF9400000) continue;
        if ((cur[2] & 0xFFC00000) != 0xF9400000) continue;
        extra = cur - adrpPtr;
        break;
    }
    if (extra < 0) return NO;
    adrpPtr += extra;

    void **gAPIs = (void **)emulate_adrp_ldr(adrpPtr[0], adrpPtr[1], (uint64_t)adrpPtr);
    if (!gAPIs || !*gAPIs) return NO;
    uint8_t *vtable = **(uint8_t ***)gAPIs;

    uint8_t *slot = NULL;
    uint32_t *movPtr = adrpPtr + 6;
    if ((*movPtr & 0x7F800000) == 0x52800000) {
        slot = vtable + ((*movPtr & 0x1FFFE0) >> 5);
    } else if ((*movPtr & 0xFFE00C00) == 0xF8400C00) {
        slot = vtable + ((*movPtr & 0x1FF000) >> 12);
    } else {
        uint32_t ldr2 = adrpPtr[3];
        if ((ldr2 & 0xBFC00000) != 0xB9400000) return NO;
        uint32_t size = (ldr2 & 0xC0000000) >> 30;
        slot = vtable + (((ldr2 & 0x3FFC00) >> 10) << size);
    }

    kern_return_t kr = jessi_worker_vm_protect(mach_task_self(), (mach_vm_address_t)slot, sizeof(uintptr_t), false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) set_tpro_writable(YES);
    if (original) *original = *(void **)slot;
    *(uint64_t *)slot = (uint64_t)replacement;
    jessi_worker_vm_protect(mach_task_self(), (mach_vm_address_t)slot, sizeof(uintptr_t), false, PROT_READ);
    if (kr != KERN_SUCCESS) set_tpro_writable(NO);
    return YES;
}

static void *(*orig_dyld_dlopen)(void *apis, const char *path, int mode);

static void *hook_dyld_dlopen(void *apis, const char *path, int mode) {
    static const char *const UIKitPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if (path && strncmp(path, UIKitPath, strlen(UIKitPath)) == 0) {
        hook_dyld_api("dlopen", 2, NULL, (void *)orig_dyld_dlopen);
        return RTLD_MAIN_ONLY;
    }
    return orig_dyld_dlopen(apis, path, mode);
}

static void do_nothing(void) {}

__attribute__((visibility("default")))
int UIApplicationMain(int argc, char *argv[], NSString *principalClassName, NSString *delegateClassName) {
    NSLog(@"[JESSI worker] running as an app-type process; waiting for the job");
    [NSTimer scheduledTimerWithTimeInterval:1e9 repeats:YES block:^(NSTimer *timer) {}];
    while (1) CFRunLoopRun();
}

__attribute__((visibility("default")))
int NSExtensionMain(int argc, char *argv[]) {
    Method validate = class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:"));
    if (validate) method_setImplementation(validate, (IMP)do_nothing);

    if (!hook_dyld_api("dlopen", 2, (void **)&orig_dyld_dlopen, (void *)hook_dyld_dlopen)) {
        NSLog(@"[JESSI worker] couldn't redirect UIKit's UIApplicationMain; continuing with the real one");
    }
    int (*realMain)(int, char **) = (int (*)(int, char **))dlsym(RTLD_NEXT, "NSExtensionMain");
    return realMain(argc, argv);
}
