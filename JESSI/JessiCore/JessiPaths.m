#import "JessiPaths.h"

bool jessi_is_running_on_macos(void);

@implementation JessiPaths

+ (NSString *)documentsDirectory {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

+ (NSString *)serversRoot {
    return [[self documentsDirectory] stringByAppendingPathComponent:@"servers"]; 
}

+ (NSString *)legacyRuntimesRoot {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [appSupport stringByAppendingPathComponent:@"Runtimes"];
}

+ (NSString *)runtimesRoot {
    if (jessi_is_running_on_macos()) return [self legacyRuntimesRoot];
    return [[self documentsDirectory] stringByAppendingPathComponent:@"Runtimes"];
}

+ (NSString *)pairingFilePath {
    return [[self documentsDirectory] stringByAppendingPathComponent:@"pairingFile.plist"];
}

+ (NSString *)legacyPairingFilePath {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[appSupport stringByAppendingPathComponent:@"Pairing"] stringByAppendingPathComponent:@"pairingFile.plist"];
}

+ (BOOL)isInstalledRuntimePath:(NSString *)path {
    return [path rangeOfString:@"/Library/Application Support/"].location != NSNotFound ||
           [path rangeOfString:@"/Documents/Runtimes/"].location != NSNotFound;
}

+ (void)ensureBaseDirectories {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *paths = @[[self serversRoot]];
    for (NSString *p in paths) {
        if (![fm fileExistsAtPath:p]) {
            [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
}

+ (void)migrateLegacyStorage {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *legacy = [self legacyRuntimesRoot];
    NSString *dest = [self runtimesRoot];
    if (![legacy isEqualToString:dest] && [fm fileExistsAtPath:legacy]) {
        [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *name in [fm contentsOfDirectoryAtPath:legacy error:nil]) {
            NSString *src = [legacy stringByAppendingPathComponent:name];
            if ([name containsString:@".staging-"] || [name containsString:@".backup-"]) {
                [fm removeItemAtPath:src error:nil];
                continue;
            }
            NSString *dst = [dest stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:dst]) {
                NSLog(@"[JESSI] %@ already exists in Documents/Runtimes; removing the old copy", name);
                [fm removeItemAtPath:src error:nil];
                continue;
            }
            NSError *error = nil;
            if ([fm moveItemAtPath:src toPath:dst error:&error]) {
                NSLog(@"[JESSI] Moved runtime %@ to Documents/Runtimes", name);
            } else {
                NSLog(@"[JESSI] Couldn't move runtime %@ to Documents/Runtimes: %@", name, error);
            }
        }
        if ([[fm contentsOfDirectoryAtPath:legacy error:nil] count] == 0) {
            [fm removeItemAtPath:legacy error:nil];
        }
    }

    if ([fm fileExistsAtPath:dest]) {
        NSURL *destURL = [NSURL fileURLWithPath:dest isDirectory:YES];
        [destURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }

    NSString *legacyPairing = [self legacyPairingFilePath];
    if ([fm fileExistsAtPath:legacyPairing]) {
        NSString *pairing = [self pairingFilePath];
        if ([fm fileExistsAtPath:pairing]) {
            [fm removeItemAtPath:legacyPairing error:nil];
        } else if ([fm moveItemAtPath:legacyPairing toPath:pairing error:nil]) {
            NSLog(@"[JESSI] Moved the pairing file to Documents");
        }
        NSString *legacyDir = [legacyPairing stringByDeletingLastPathComponent];
        if ([[fm contentsOfDirectoryAtPath:legacyDir error:nil] count] == 0) {
            [fm removeItemAtPath:legacyDir error:nil];
        }
    }
}

@end
