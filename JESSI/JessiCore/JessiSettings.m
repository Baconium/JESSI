#import "JessiSettings.h"

static NSString *const kJessiJavaVersion = @"jessi.javaVersion";
static NSString *const kJessiMaxHeapMB = @"jessi.maxHeapMB";
static NSString *const kJessiFlagNettyNoNative = @"jessi.jvm.flagNettyNoNative";
static NSString *const kJessiFlagJnaNoSys = @"jessi.jvm.flagJnaNoSys";
static NSString *const kJessiLaunchArgs = @"jessi.jvm.launchArgs";
static NSString *const kJessiIOS26JIT = @"jessi.jit.ios26";

@implementation JessiSettings

+ (instancetype)shared {
    static JessiSettings *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[JessiSettings alloc] init];
    });
    [s load];
    return s;
}

+ (NSArray<NSString *> *)availableJavaVersions {
    NSMutableArray<NSString *> *available = [NSMutableArray array];
    NSBundle *b = [NSBundle mainBundle];
    NSString *bundleRoot = b.bundlePath;
    NSString *resourceRoot = b.resourcePath;
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    if (bundleRoot.length) [roots addObject:bundleRoot];
    if (resourceRoot.length && ![resourceRoot isEqualToString:bundleRoot]) [roots addObject:resourceRoot];
    if (bundleRoot.length) {
        NSString *resourcesUnderBundle = [bundleRoot stringByAppendingPathComponent:@"Resources"];
        if (![roots containsObject:resourcesUnderBundle]) [roots addObject:resourcesUnderBundle];
    }

    for (NSString *ver in @[@"8", @"17", @"21"]) {
        for (NSString *root in roots) {
            NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"java%@", ver]];
            if ([fm fileExistsAtPath:path]) {
                [available addObject:ver];
                break;
            }
        }
    }

    if (![available containsObject:@"8"]) {
        NSString *genericPath = nil;
        for (NSString *root in roots) {
            NSString *candidate = [root stringByAppendingPathComponent:@"java"];
            if ([fm fileExistsAtPath:candidate]) {
                genericPath = candidate;
                break;
            }
        }

        if (genericPath.length) {
            NSString *releasePath = [genericPath stringByAppendingPathComponent:@"release"];
            NSString *releaseContent = [NSString stringWithContentsOfFile:releasePath encoding:NSUTF8StringEncoding error:nil];

            if ([releaseContent containsString:@"1.8.0"]) {
                [available insertObject:@"8" atIndex:0];
            } else if ([releaseContent containsString:@"\"17."]) {
                NSMutableArray *newAvailable = [NSMutableArray array];
                [newAvailable addObject:@"8"];
                [newAvailable addObjectsFromArray:available];
                available = newAvailable;
            }
        }
    }

    if (available.count == 0) {
        [available addObject:@"8"];
    }

    return [available sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a integerValue] - [b integerValue] > 0 ? NSOrderedDescending : NSOrderedAscending;
    }];
}

- (void)load {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *savedVersion = [d stringForKey:kJessiJavaVersion];

    if (!savedVersion) {
        NSArray *available = [JessiSettings availableJavaVersions];
        if ([available containsObject:@"21"]) {
            self.javaVersion = @"21";
        } else if ([available containsObject:@"17"]) {
            self.javaVersion = @"17";
        } else {
            self.javaVersion = @"8";
        }
    } else {
        self.javaVersion = savedVersion;
    }
    
    NSInteger mb = [d integerForKey:kJessiMaxHeapMB];
    self.maxHeapMB = (mb > 0) ? mb : 768;

    if ([d objectForKey:kJessiFlagNettyNoNative] == nil) {
        self.flagNettyNoNative = YES;
    } else {
        self.flagNettyNoNative = [d boolForKey:kJessiFlagNettyNoNative];
    }

    if ([d objectForKey:kJessiFlagJnaNoSys] == nil) {
        self.flagJnaNoSys = NO;
    } else {
        self.flagJnaNoSys = [d boolForKey:kJessiFlagJnaNoSys];
    }

    if ([d objectForKey:kJessiIOS26JIT] == nil) {
        self.iOS26JITSupport = NO;
    } else {
        self.iOS26JITSupport = [d boolForKey:kJessiIOS26JIT];
    }

    NSString *args = [d stringForKey:kJessiLaunchArgs];
    if (args) self.launchArguments = args; else self.launchArguments = @"";
}

- (void)save {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.javaVersion ?: @"8" forKey:kJessiJavaVersion];
    [d setInteger:self.maxHeapMB forKey:kJessiMaxHeapMB];

    [d setBool:self.flagNettyNoNative forKey:kJessiFlagNettyNoNative];
    [d setBool:self.flagJnaNoSys forKey:kJessiFlagJnaNoSys];
    [d setBool:self.iOS26JITSupport forKey:kJessiIOS26JIT];
    [d setObject:self.launchArguments ?: @"" forKey:kJessiLaunchArgs];
}

@end
