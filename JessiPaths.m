#import "JessiPaths.h"

@implementation JessiPaths

+ (NSString *)documentsDirectory {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

+ (NSString *)serversRoot {
    return [[self documentsDirectory] stringByAppendingPathComponent:@"servers"]; 
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

@end
