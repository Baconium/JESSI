#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^JessiWorkerJITStarter)(pid_t pid, void (^log)(NSString *line), void (^done)(NSString * _Nullable error));

@interface JessiWorker : NSObject
@property (nonatomic, readonly) pid_t pid;
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
- (void)send:(NSDictionary *)command;
- (void)terminate;
@end

@interface JessiWorkerHost : NSObject

@property (class, nonatomic, readonly) BOOL shouldUseWorkers;
@property (class, nonatomic, readonly) BOOL workerExtensionAvailable;
@property (class, nonatomic, copy, nullable) JessiWorkerJITStarter jitStarter;

+ (JessiWorker *)launchJob:(NSDictionary *)job
                  needsJIT:(BOOL)needsJIT
                     onLog:(void (^)(NSString *line))onLog
                   onEvent:(void (^)(NSDictionary *event))onEvent
                    onExit:(void (^)(int code, NSString * _Nullable problem))onExit;

@end

void jessi_keep_extension_running_in_background(id extension);

NS_ASSUME_NONNULL_END

int jessi_worker_run_tool(int argc, char *argv[]);
