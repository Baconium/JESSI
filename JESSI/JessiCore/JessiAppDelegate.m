#import "JessiAppDelegate.h"
#import "JESSI-Swift.h"

@implementation JessiAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [JessiPaths migrateLegacyStorage];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [JessiSwiftUIEntry makeRootTabViewController];
    [self.window makeKeyAndVisible];

    return YES;
}

@end
