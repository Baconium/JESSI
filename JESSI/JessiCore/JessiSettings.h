#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JessiSettings : NSObject

@property (nonatomic, copy) NSString *javaVersion;
@property (nonatomic) NSInteger maxHeapMB;

@property (nonatomic) BOOL txmSupport;

@property (nonatomic) BOOL flagNettyNoNative;
@property (nonatomic) BOOL flagJnaNoSys;

+ (instancetype)shared;
+ (NSArray<NSString *> *)availableJavaVersions;
- (void)load;
- (void)save;

@property (nonatomic, copy) NSString *launchArguments;
@property (nonatomic, copy) NSString *curseForgeAPIKey;

@end

NS_ASSUME_NONNULL_END
