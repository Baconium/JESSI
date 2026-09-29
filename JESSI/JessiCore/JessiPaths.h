#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JessiPaths : NSObject
+ (NSString *)documentsDirectory;
+ (NSString *)serversRoot;
+ (NSString *)runtimesRoot;
+ (NSString *)legacyRuntimesRoot;
+ (NSString *)pairingFilePath;
+ (BOOL)isInstalledRuntimePath:(NSString *)path;
+ (void)ensureBaseDirectories;
+ (void)migrateLegacyStorage;
@end

NS_ASSUME_NONNULL_END
