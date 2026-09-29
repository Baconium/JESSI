#import <Foundation/Foundation.h>
#import <dirent.h>
#import <errno.h>
#import <limits.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

#import "JessiPrebootRedirect.h"
#import "fishhook.h"
#import "../SwiftUI/JessiJITCheck.h"

static const char *const kPrebootPath = "/private/preboot";
static const char *const kStandInVolume =
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

static char s_standInRoot[PATH_MAX];
static char s_standInPrefix[PATH_MAX];
static size_t s_standInPrefixLength;

static DIR *(*jessi_orig_opendir)(const char *);
static int (*jessi_orig_access)(const char *, int);

static DIR *jessi_preboot_opendir(const char *path) {
    DIR *dir = jessi_orig_opendir(path);
    if (dir || !path || strcmp(path, kPrebootPath) != 0) return dir;
    return jessi_orig_opendir(s_standInRoot);
}

static int jessi_preboot_access(const char *path, int mode) {
    if (path && strncmp(path, s_standInPrefix, s_standInPrefixLength) == 0) {
        char mapped[PATH_MAX];
        snprintf(mapped, sizeof(mapped), "%s/%s", s_standInRoot, path + strlen(kPrebootPath) + 1);
        return jessi_orig_access(mapped, mode);
    }
    return jessi_orig_access(path, mode);
}

static BOOL jessi_prepare_stand_in(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"jessi-preboot"];
    NSString *volume = [root stringByAppendingPathComponent:@(kStandInVolume)];
    NSString *fud = [volume stringByAppendingPathComponent:@"usr/standalone/firmware/FUD"];
    NSString *txmImage = [fud stringByAppendingPathComponent:@"Ap,TrustedExecutionMonitor.img4"];

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:fud withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }
    if (jessi_is_txm_device()) {
        if (![fm fileExistsAtPath:txmImage] && ![fm createFileAtPath:txmImage contents:[NSData data] attributes:nil]) {
            return NO;
        }
    } else {
        [fm removeItemAtPath:txmImage error:nil];
    }

    strlcpy(s_standInRoot, root.fileSystemRepresentation, sizeof(s_standInRoot));
    snprintf(s_standInPrefix, sizeof(s_standInPrefix), "%s/%s/", kPrebootPath, kStandInVolume);
    s_standInPrefixLength = strlen(s_standInPrefix);
    return YES;
}

void jessi_install_preboot_redirect(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (jessi_is_running_on_macos()) return;
        DIR *probe = opendir(kPrebootPath);
        if (probe) {
            closedir(probe);
            return;
        }

        if (!jessi_prepare_stand_in()) {
            NSLog(@"[JESSI] Couldn't create the preboot stand-in; the JVM's TXM probe may crash");
            return;
        }

        struct rebinding rebindings[] = {
            {"opendir", (void *)jessi_preboot_opendir, (void **)&jessi_orig_opendir},
            {"access", (void *)jessi_preboot_access, (void **)&jessi_orig_access},
        };
        if (rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0])) != 0) {
            NSLog(@"[JESSI] Failed to install the preboot redirect");
        }
    });
}
