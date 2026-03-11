// I love skidding from pojav :3 

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <sys/utsname.h>
#import <dirent.h>
#import <limits.h>
#import <stdio.h>
#import <string.h>
#import <mach-o/dyld.h>
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

static void jessi_append_livecontainer_log(NSString *line) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length == 0 || line.length == 0) return;

    NSString *path = [docs stringByAppendingPathComponent:@"livecontainerdetectiondebug.log"];
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [data writeToFile:path atomically:YES];
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (NSException *exception) {
        (void)exception;
    } @finally {
        [handle closeFile];
    }
}

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

    if (getEntitlementValue(@"dynamic-codesigning") || getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        return YES;
    }

    int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return NO;
    }

    return (flags & CS_DEBUGGED) != 0;
}

static __attribute__((unused)) BOOL jessi_is_debugger_attached(void) {
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

BOOL jessi_is_trollstore_installed(void) {
    NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
    return access(tsPath.UTF8String, F_OK) == 0;
}

BOOL jessi_is_livecontainer_installed(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *logpath = [docs stringByAppendingPathComponent:@"uhislivecontainerinstalledorlikenahnotsomuch.log"];
    NSMutableString *log = [NSMutableString string];

    [log appendString:@"\nloaded images:\n"];

    BOOL detected = NO;

    uint32_t count = _dyld_image_count();
    [log appendFormat:@"image count: %u\n\n", count];

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;

        NSString *lower = [[NSString stringWithUTF8String:name] lowercaseString];
        BOOL match = [lower containsString:@"tweakinjector.dylib"] || [lower containsString:@"tweakloader.dylib"];

        [log appendFormat:@"[%u] %s %s\n",
            i,
            name,
            match ? "<- aha!" : ""
        ];

        if (match) {
            detected = YES;
        }
    }

    [log appendFormat:@"\nlivecontainer detected: %s\n", detected ? "yeah" : "fuck nah"];
    [log writeToFile:logpath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    return detected;
}

const char * _Nullable jessi_team_identifier(void) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return NULL;

    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.team-identifier"), NULL);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *team = [(__bridge NSString *)value copy];
        CFRelease(value);
        if (team.length > 0) {
            return strdup(team.UTF8String);
        }
        return NULL;
    }
    if (value) CFRelease(value);

    value = SecTaskCopyValueForEntitlement(task, CFSTR("application-identifier"), NULL);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *appID = [(__bridge NSString *)value copy];
        CFRelease(value);
        if (appID.length > 0) {
            NSArray<NSString *> *parts = [appID componentsSeparatedByString:@"."];
            NSString *prefix = parts.firstObject ?: @"";
            if (prefix.length > 0) {
                return strdup(prefix.UTF8String);
            }
        }
        return NULL;
    }
    if (value) CFRelease(value);

    return NULL;
}
