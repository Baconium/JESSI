#import "JessiSettings.h"

static NSString *const kJessiJavaVersion = @"jessi.javaVersion";
static NSString *const kJessiMaxHeapMB = @"jessi.maxHeapMB";
static NSString *const kJessiFlagNettyNoNative = @"jessi.jvm.flagNettyNoNative";
static NSString *const kJessiFlagJnaNoSys = @"jessi.jvm.flagJnaNoSys";
static NSString *const kJessiLaunchArgs = @"jessi.jvm.launchArgs";
static NSString *const kJessiTXMSupport = @"jessi.txmSupport";
static NSString *const kJessiCurseForgeAPIKey = @"jessi.mods.curseforgeApiKey";

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

    BOOL isIOS26OrLater = NO;
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    if (v.majorVersion >= 26) isIOS26OrLater = YES;

    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    if (bundleRoot.length) [roots addObject:bundleRoot];
    if (resourceRoot.length && ![resourceRoot isEqualToString:bundleRoot]) [roots addObject:resourceRoot];
    if (bundleRoot.length) {
        NSString *resourcesUnderBundle = [bundleRoot stringByAppendingPathComponent:@"Resources"];
        if (![roots containsObject:resourcesUnderBundle]) [roots addObject:resourcesUnderBundle];
    }

    for (NSString *ver in @[@"8", @"17", @"21"]) {
        if (isIOS26OrLater && [ver isEqualToString:@"8"]) {
            continue;
        }
        for (NSString *root in roots) {
            NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"java%@", ver]];
            if ([fm fileExistsAtPath:path]) {
                [available addObject:ver];
                break;
            }
        }
    }

    if (!isIOS26OrLater && ![available containsObject:@"8"] && ![available containsObject:@"17"] && ![available containsObject:@"21"]) {
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

            if ([releaseContent containsString:@"1.8.0"] || [releaseContent containsString:@"\"1.8"]) {
                [available addObject:@"8"];
            } else if ([releaseContent containsString:@"\"17."]) {
                [available addObject:@"17"];
            } else if ([releaseContent containsString:@"\"21."]) {
                [available addObject:@"21"];
            }
        }
    }

    NSURL *appSupport = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    NSString *runtimesRoot = [[appSupport URLByAppendingPathComponent:@"Runtimes" isDirectory:YES] path];
    if (runtimesRoot.length) {
        for (NSString *ver in @[@"8", @"17", @"21"]) {
            if (isIOS26OrLater && [ver isEqualToString:@"8"]) {
                continue;
            }
            NSString *dir = [runtimesRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"jre%@", ver]];
            if ([fm fileExistsAtPath:dir] && ![available containsObject:ver]) {
                [available addObject:ver];
            }
        }
    }

    return [available sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a integerValue] - [b integerValue] > 0 ? NSOrderedDescending : NSOrderedAscending;
    }];
}

- (void)load {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *savedVersion = [d stringForKey:kJessiJavaVersion];

    NSArray<NSString *> *available = [JessiSettings availableJavaVersions];

    NSString *(^pickBestAvailable)(void) = ^NSString *{
        if ([available containsObject:@"21"]) return @"21";
        if ([available containsObject:@"17"]) return @"17";
        if ([available containsObject:@"8"]) return @"8";
        return available.firstObject;
    };

    if (available.count > 0) {
        if (savedVersion.length && [available containsObject:savedVersion]) {
            self.javaVersion = savedVersion;
        } else {
            self.javaVersion = pickBestAvailable() ?: @"21";
        }
    } else {
        self.javaVersion = savedVersion.length ? savedVersion : @"21";
    }
    
    NSInteger mb = [d integerForKey:kJessiMaxHeapMB];
    self.maxHeapMB = (mb > 0) ? mb : 768;

    if ([d objectForKey:kJessiTXMSupport] == nil) {
        self.txmSupport = YES;
    } else {
        self.txmSupport = [d boolForKey:kJessiTXMSupport];
    }

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

    NSString *args = [d stringForKey:kJessiLaunchArgs];
    if (args) self.launchArguments = args; else self.launchArguments = @"";

    NSString *key = [d stringForKey:kJessiCurseForgeAPIKey];
    if (key) self.curseForgeAPIKey = key; else self.curseForgeAPIKey = @"";
}

- (void)save {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.javaVersion ?: @"8" forKey:kJessiJavaVersion];
    [d setInteger:self.maxHeapMB forKey:kJessiMaxHeapMB];

    [d setBool:self.flagNettyNoNative forKey:kJessiFlagNettyNoNative];
    [d setBool:self.flagJnaNoSys forKey:kJessiFlagJnaNoSys];
    [d setObject:self.launchArguments ?: @"" forKey:kJessiLaunchArgs];
    [d setBool:self.txmSupport forKey:kJessiTXMSupport];
    [d setObject:self.curseForgeAPIKey ?: @"" forKey:kJessiCurseForgeAPIKey];
}

@end