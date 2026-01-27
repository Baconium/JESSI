#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JessiPaths : NSObject
+ (NSString *)documentsDirectory;
+ (NSString *)serversRoot;
+ (void)ensureBaseDirectories;
@end

NS_ASSUME_NONNULL_END
