// I love skidding from pojav :3 

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <sys/utsname.h>
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

#define CS_DEBUGGED 0x10000000

CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef entitlement, CFErrorRef *error);
void *SecTaskCreateFromSelf(CFAllocatorRef allocator);

static BOOL getEntitlementValue(NSString *key) {
    void *task = SecTaskCreateFromSelf(NULL);
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
