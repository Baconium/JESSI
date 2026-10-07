#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JessiPaths : NSObject
+ (void)useHomeDirectory:(NSString *)homeDirectory;
+ (NSString *)homeDirectory;
+ (NSBundle *)appBundle;
+ (void)useAppBundlePath:(NSString *)bundlePath;
+ (NSString *)documentsDirectory;
+ (NSString *)applicationSupportDirectory;
+ (NSString *)serversRoot;
+ (NSString *)runtimesRoot;
+ (NSString *)legacyRuntimesRoot;
+ (NSString *)pairingFilePath;
+ (BOOL)isInstalledRuntimePath:(NSString *)path;
+ (void)ensureBaseDirectories;
+ (void)migrateLegacyStorage;
@end

NS_ASSUME_NONNULL_END
