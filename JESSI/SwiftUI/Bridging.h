#import "../JessiCore/JessiPaths.h"
#import "../JessiCore/JessiSettings.h"
#import "../JessiCore/JessiServerService.h"

#ifdef __cplusplus
extern "C" {
#endif
int jessi_tool_main(int argc, char *argv[]);
int jessi_spawn_tool(int argc, char *argv[]);


#ifdef __cplusplus
}
#endif

#import "JessiJITCheck.h"

@interface NSExtension : NSObject
+ (instancetype _Nullable)extensionWithIdentifier:(NSString * _Nonnull)identifier error:(NSError * _Nullable * _Nullable)error;
- (void)beginExtensionRequestWithInputItems:(NSArray * _Nonnull)inputItems completion:(void (^ _Nonnull)(NSUUID * _Nonnull requestIdentifier))completion;
- (int)pidForRequestIdentifier:(NSUUID * _Nonnull)requestIdentifier;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID * _Nonnull)requestIdentifier;
- (void)setRequestCancellationBlock:(void (^ _Nullable)(NSUUID * _Nonnull uuid, NSError * _Nullable error))cancellationBlock;
- (void)setRequestCompletionBlock:(void (^ _Nullable)(NSUUID * _Nonnull uuid, NSArray * _Nullable extensionItems))completionBlock;
- (void)setRequestInterruptionBlock:(void (^ _Nullable)(NSUUID * _Nonnull uuid))interruptionBlock;
@end
