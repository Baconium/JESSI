#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol JessiServerServiceDelegate <NSObject>
- (void)serverServiceDidUpdateConsole:(NSString *)consoleText;
- (void)serverServiceDidChangeRunning:(BOOL)isRunning;
@end

@interface JessiServerService : NSObject
@property (nonatomic, weak, nullable) id<JessiServerServiceDelegate> delegate;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

- (NSArray<NSString *> *)availableServerFolders;
- (NSString *)serversRoot;

- (void)startServerNamed:(NSString *)serverName;
- (void)stopServer;
- (void)clearConsole;
- (BOOL)sendRcon:(NSString *)command;

- (void)importServerJarFromURL:(NSURL *)url serverNameHint:(NSString *)nameHint completion:(void (^)(NSError * _Nullable error, NSString * _Nullable serverName))completion;

@end

NS_ASSUME_NONNULL_END
