// I love skidding from pojav :3 

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <sys/utsname.h>
#import <dirent.h>
#import <limits.h>
#import <stdio.h>
#import <string.h>
#if __has_include(<sys/codesign.h>)
#import <sys/codesign.h>
#else
#import <sys/types.h>
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
int csops(pid_t pid, int ops, void *useraddr, size_t nbytes);
#endif

#import <dlfcn.h>

#if __has_include(<Security/SecTask.h>)
#import <Security/SecTask.h>
#else
typedef const struct __SecTask *SecTaskRef;
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);
#endif

#define CS_DEBUGGED 0x10000000

static BOOL getEntitlementValue(NSString *key) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return NO;

    CFTypeRef value = SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)key, NULL);
    if (!value) return NO;

    BOOL result = NO;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    }

    CFRelease(value);
    return result;
}

BOOL jessi_check_jit_enabled(void) {

    if (getEntitlementValue(@"dynamic-codesigning")) {
        return YES;
    }

    int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return NO;
    }

    return (flags & CS_DEBUGGED) != 0;
}

BOOL jessi_is_ios26_or_later(void) {
    if (@available(iOS 26, *)) {
        return YES;
    }
    return NO;
}

BOOL jessi_is_txm_device(void) {
    if (!jessi_is_ios26_or_later()) return NO;

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

    return txmPath[0] != '\0' && access(txmPath, F_OK) == 0;
}
