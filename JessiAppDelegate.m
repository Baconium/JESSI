#import "JessiAppDelegate.h"
#import "jessi-Swift.h"

@implementation JessiAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [JessiSwiftUIEntry makeRootTabViewController];
    [self.window makeKeyAndVisible];

    return YES;
}

@end
