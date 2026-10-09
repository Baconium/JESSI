#import "JessiServerService.h"

#import "JessiPaths.h"
#import "JessiSettings.h"
#import "JessiWorkerHost.h"

#import <TargetConditionals.h>
#if TARGET_OS_OSX && !TARGET_OS_MACCATALYST
typedef NSInteger UIBackgroundTaskIdentifier;
static const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid = -1;
#else
#import <UIKit/UIKit.h>
#endif
#import <sys/socket.h>
#import <netinet/in.h>
#import <sys/time.h>
#import <unistd.h>
#import <signal.h>
#import <fcntl.h>
#import <dlfcn.h>

#import <spawn.h>
#import "../SwiftUI/JessiJITCheck.h"

extern int jessi_server_main(int argc, char *argv[]);

NSString *const JessiPumpkinLibraryFileName = @"libpumpkin_embed.dylib";

typedef int (*JessiPumpkinRunFn)(const char *dir);
typedef void (*JessiPumpkinStopFn)(void);
static const int JessiPumpkinErrAlreadyStarted = -1;
static const int JessiPumpkinErrBadDirectory = -2;
static const int JessiPumpkinErrRuntime = -3;
static JessiPumpkinStopFn g_pumpkinStop = NULL;

typedef int (*JessiPumpkinPromptFn)(const char *plugin, const char *version, const char *permissions);
typedef void (*JessiPumpkinSetPromptFn)(JessiPumpkinPromptFn callback);
static const int JessiPumpkinPromptAllow = 1;
static const int JessiPumpkinPromptDeny = 0;
static const int JessiPumpkinPromptSkip = -1;
static const NSTimeInterval JessiPumpkinPromptTimeout = 600;

static UIViewController *jessi_top_view_controller(void) {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)candidate; break; }
    }
    UIWindow *window = nil;
    for (UIWindow *w in scene.windows) {
        if (w.isKeyWindow) { window = w; break; }
    }
    UIViewController *controller = (window ?: scene.windows.firstObject).rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

static void jessi_when_app_active(void (^block)(void)) {
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        block();
        return;
    }
    __block id token = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                       object:nil
                                                                        queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:token];
        block();
    }];
}

static void jessi_present_pumpkin_permission_prompt(NSString *name, NSString *pluginVersion, NSString *permissions, void (^completion)(int answer)) {
    NSMutableString *list = [NSMutableString string];
    for (NSString *line in [permissions componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
        [list appendFormat:@"\n• %@", parts[0]];
        if (parts.count > 1 && parts[1].length > 0) [list appendFormat:@": %@", parts[1]];
    }
    NSString *message = [NSString stringWithFormat:@"\"%@\" %@ is asking for these permissions:\n%@\n\nOnly allow plugins you trust. Your answer is remembered for this plugin file.", name, pluginVersion, list];

    dispatch_async(dispatch_get_main_queue(), ^{
        jessi_when_app_active(^{
            UIViewController *presenter = jessi_top_view_controller();
            if (!presenter) {
                completion(JessiPumpkinPromptSkip);
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Allow Plugin Permissions?" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Deny" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                completion(JessiPumpkinPromptDeny);
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Allow" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                completion(JessiPumpkinPromptAllow);
            }]];
            [presenter presentViewController:alert animated:YES completion:nil];
        });
    });
}

static int jessi_pumpkin_permission_prompt(const char *plugin, const char *version, const char *permissions) {
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block int answer = JessiPumpkinPromptSkip;
    jessi_present_pumpkin_permission_prompt(plugin ? @(plugin) : @"", version ? @(version) : @"", permissions ? @(permissions) : @"", ^(int choice) {
        answer = choice;
        dispatch_semaphore_signal(answered);
    });
    if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(JessiPumpkinPromptTimeout * NSEC_PER_SEC))) != 0) {
        return JessiPumpkinPromptSkip;
    }
    return answer;
}

static NSString *const JessiServerRunningKey = @"jessi.server.running";
static NSString *const JessiServerRunningChanged = @"JessiServerRunningChanged";
static BOOL g_serverRunning = NO;

static BOOL jessi_mc_version_at_least(NSString *version, NSString *threshold) {
    NSArray<NSString *> *a = [version componentsSeparatedByString:@"."];
    NSArray<NSString *> *b = [threshold componentsSeparatedByString:@"."];
    NSUInteger n = MAX(a.count, b.count);
    for (NSUInteger i = 0; i < n; i++) {
        int va = (i < a.count) ? [a[i] intValue] : 0;
        int vb = (i < b.count) ? [b[i] intValue] : 0;
        if (va != vb) return va >= vb;
    }
    return YES;
}

static NSString *jessi_recommended_java_version(NSString *mcVersion) {
    if (jessi_mc_version_at_least(mcVersion, @"26.0"))  return @"25";
    if (jessi_mc_version_at_least(mcVersion, @"1.20.5")) return @"21";
    if (jessi_mc_version_at_least(mcVersion, @"1.17"))   return @"17";
    return @"8";
}

static NSString *jessi_server_pid_file_path(NSString *dir) {
    return [dir stringByAppendingPathComponent:@".jessi_server_pid"];
}

static NSString *jessi_capture_cmd(const char *cmd) {
    if (!cmd) return @"";
    FILE *fp = popen(cmd, "r");
    if (!fp) return @"";

    NSMutableString *out = [NSMutableString string];
    char buf[512];
    while (fgets(buf, sizeof(buf), fp)) {
        [out appendString:[NSString stringWithUTF8String:buf] ?: @""];
    }
    pclose(fp);
    return out;
}

static BOOL jessi_pid_alive(pid_t pid) {
    if (pid <= 1) return NO;
    return kill(pid, 0) == 0;
}

static BOOL jessi_terminate_pid(pid_t pid) {
    if (pid <= 1) return NO;
    if (!jessi_pid_alive(pid)) return YES;

    kill(pid, SIGTERM);
    for (int i = 0; i < 15; i++) {
        if (!jessi_pid_alive(pid)) return YES;
        usleep(100000);
    }

    kill(pid, SIGKILL);
    for (int i = 0; i < 10; i++) {
        if (!jessi_pid_alive(pid)) return YES;
        usleep(100000);
    }

    return !jessi_pid_alive(pid);
}

static NSSet<NSNumber *> *jessi_pids_listening_on_port(int port) {
    NSString *cmd = [NSString stringWithFormat:@"/usr/sbin/lsof -nP -iTCP:%d -sTCP:LISTEN -t 2>/dev/null", port];
    NSString *out = jessi_capture_cmd(cmd.UTF8String);
    NSMutableSet<NSNumber *> *pids = [NSMutableSet set];

    NSArray<NSString *> *lines = [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;
        pid_t pid = (pid_t)[trimmed intValue];
        if (pid > 1) [pids addObject:@(pid)];
    }
    return pids;
}

static NSString *jessi_command_for_pid(pid_t pid) {
    NSString *cmd = [NSString stringWithFormat:@"ps -p %d -o command= 2>/dev/null", pid];
    return [jessi_capture_cmd(cmd.UTF8String) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL jessi_server_dir_is_pumpkin(NSString *dir);

static const int JessiDefaultGamePort = 25565;
static const int JessiDefaultRconPort = 25575;
static int g_activeGamePort = 0;

static int jessi_port_value(NSString *text, int fallback) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" \t"]];
    NSRange colon = [trimmed rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) trimmed = [trimmed substringFromIndex:colon.location + 1];
    int port = trimmed.intValue;
    return (port > 0 && port <= 65535) ? port : fallback;
}

static NSDictionary<NSString *, NSString *> *jessi_read_properties(NSString *path) {
    NSMutableDictionary<NSString *, NSString *> *kv = [NSMutableDictionary dictionary];
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange r = [line rangeOfString:@"="];
        if (r.location == NSNotFound) continue;
        NSString *k = [line substringToIndex:r.location];
        if (k.length) kv[k] = [line substringFromIndex:r.location + 1] ?: @"";
    }
    return kv;
}

static NSString *jessi_toml_get_value(NSString *toml, NSString *section, NSString *key) {
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSString *header = [NSString stringWithFormat:@"[%@]", section];
    BOOL inSection = NO;
    for (NSString *raw in [toml componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:ws];
        if ([line hasPrefix:@"["]) {
            inSection = [line isEqualToString:header];
            continue;
        }
        if (!inSection) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        if ([[[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws] isEqualToString:key]) {
            return [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
        }
    }
    return nil;
}

static NSArray<NSNumber *> *jessi_server_ports_in_dir(NSString *dir) {
    if (jessi_server_dir_is_pumpkin(dir)) {
        NSString *toml = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"pumpkin.toml"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
        return @[@(jessi_port_value(jessi_toml_get_value(toml, @"networking.java", @"address"), JessiDefaultGamePort)),
                 @(jessi_port_value(jessi_toml_get_value(toml, @"networking.rcon", @"address"), JessiDefaultRconPort))];
    }
    NSDictionary *kv = jessi_read_properties([dir stringByAppendingPathComponent:@"server.properties"]);
    return @[@(jessi_port_value(kv[@"server-port"], JessiDefaultGamePort)),
             @(jessi_port_value(kv[@"rcon.port"], JessiDefaultRconPort))];
}

static BOOL jessi_tcp_port_in_use(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    BOOL inUse = bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 && errno == EADDRINUSE;
    close(fd);
    return inUse;
}

static int jessi_free_local_port(int preferred) {
    if (!jessi_tcp_port_in_use(preferred)) return preferred;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return preferred;
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(addr);
    int port = preferred;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0 && getsockname(fd, (struct sockaddr *)&addr, &length) == 0) {
        port = ntohs(addr.sin_port);
    }
    close(fd);
    return port;
}

static BOOL jessi_server_dir_is_pumpkin(NSString *dir) {
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"jessiserverconfig.json"]];
    if (!data) return NO;
    NSDictionary *config = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![config isKindOfClass:[NSDictionary class]]) return NO;
    id software = config[@"software"];
    return [software isKindOfClass:[NSString class]] && [software caseInsensitiveCompare:@"Pumpkin"] == NSOrderedSame;
}

static void jessi_redirect_stdio_to(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    close(fd);
}

static NSString *jessi_toml_set_values(NSString *toml, NSString *section, NSDictionary<NSString *, NSString *> *values) {
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSMutableArray<NSString *> *lines = [[toml componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.count && [lines.lastObject stringByTrimmingCharactersInSet:ws].length == 0) [lines removeLastObject];

    NSString *header = [NSString stringWithFormat:@"[%@]", section];
    NSUInteger headerIndex = NSNotFound;
    for (NSUInteger i = 0; i < lines.count; i++) {
        if ([[lines[i] stringByTrimmingCharactersInSet:ws] isEqualToString:header]) {
            headerIndex = i;
            break;
        }
    }
    if (headerIndex == NSNotFound) {
        if (lines.count) [lines addObject:@""];
        [lines addObject:header];
        headerIndex = lines.count - 1;
    }

    NSMutableSet<NSString *> *pending = [NSMutableSet setWithArray:values.allKeys];
    for (NSUInteger i = headerIndex + 1; i < lines.count; i++) {
        NSString *trimmed = [lines[i] stringByTrimmingCharactersInSet:ws];
        if ([trimmed hasPrefix:@"["]) break;
        NSRange eq = [trimmed rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [[trimmed substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        if (!values[key]) continue;
        lines[i] = [NSString stringWithFormat:@"%@ = %@", key, values[key]];
        [pending removeObject:key];
    }

    NSUInteger insertAt = headerIndex + 1;
    for (NSString *key in [pending.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        [lines insertObject:[NSString stringWithFormat:@"%@ = %@", key, values[key]] atIndex:insertAt++];
    }
    [lines addObject:@""];
    return [lines componentsJoinedByString:@"\n"];
}

static BOOL jessi_looks_like_jessi_java(NSString *cmd) {
    NSString *c = cmd.lowercaseString ?: @"";
    BOOL hasJava = [c containsString:@"/java"] || [c containsString:@" java "];
    BOOL hasMarker = [c containsString:@"server.jar"] || [c containsString:@"/servers/"] || [c containsString:@"jessi"];
    return hasJava && hasMarker;
}

@interface JessiServerService ()
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) NSMutableString *console;
@property (nonatomic, strong) dispatch_queue_t runQueue;
@property (nonatomic, strong) dispatch_queue_t logQueue;
@property (nonatomic, strong) dispatch_source_t logTimer;
@property (nonatomic) off_t logOffset;
@property (nonatomic) off_t stdioOffset;
@property (nonatomic, copy) NSString *activeServerDir;
@property (nonatomic, copy) NSString *activeRconPassword;
@property (nonatomic) int activeRconPort;
@property (nonatomic) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) JessiWorker *activeWorker;
@property (nonatomic) BOOL activeRunInProcess;
@property (nonatomic) BOOL stopPending;
@property (nonatomic) BOOL waitingForPorts;
@property (nonatomic, copy) void (^readNewLogOutput)(BOOL force);
@end

@implementation JessiServerService

- (instancetype)init {
    self = [super init];
    if (self) {
        _console = [NSMutableString string];
        _runQueue = dispatch_queue_create("com.baconmania.jessi.run", DISPATCH_QUEUE_SERIAL);
        _logQueue = dispatch_queue_create("com.baconmania.jessi.log", DISPATCH_QUEUE_SERIAL);
        _activeRconPort = JessiDefaultRconPort;
        _bgTask = UIBackgroundTaskInvalid;
        [JessiPaths ensureBaseDirectories];
        [[NSUserDefaults standardUserDefaults] setBool:g_serverRunning forKey:JessiServerRunningKey];
    }
    return self;
}

- (BOOL)isRunning {
    @synchronized([JessiServerService class]) {
        return g_serverRunning;
    }
}

- (void)setRunning:(BOOL)running {
    BOOL changed = NO;
    @synchronized([JessiServerService class]) {
        if (g_serverRunning != running) {
            g_serverRunning = running;
            changed = YES;
        }
    }
    if (changed) {
        [[NSUserDefaults standardUserDefaults] setBool:running forKey:JessiServerRunningKey];
        [[NSNotificationCenter defaultCenter] postNotificationName:JessiServerRunningChanged object:nil];
    }
}

- (NSString *)serversRoot { return [JessiPaths serversRoot]; }

- (BOOL)stopWillCloseApp {
    return self.isRunning && self.activeRunInProcess;
}

+ (NSInteger)activeGamePort {
    return g_activeGamePort;
}

- (void)runInWorkerWhenPortsAreFree:(NSDictionary *)job {
    [JessiWorkerHost reapOrphanedWorkers];
    NSArray<NSNumber *> *ports = @[jessi_server_ports_in_dir(job[@"dir"]).firstObject];
    NSArray<NSNumber *> *(^busyPorts)(void) = ^{
        return [ports filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *port, NSDictionary *bindings) {
            return jessi_tcp_port_in_use(port.intValue);
        }]];
    };
    if (busyPorts().count == 0) {
        [self runInWorker:job];
        return;
    }

    NSArray<NSNumber *> *busyNow = busyPorts();
    NSString *list = [[busyNow valueForKey:@"stringValue"] componentsJoinedByString:@" and "];
    NSString *waiting = [NSString stringWithFormat:@"%@ %@ still in use, probably by a server process left over from when JESSI was closed. Waiting for %@ to be released…\n",
                         busyNow.count == 1 ? @"Port" : @"Ports", list, busyNow.count == 1 ? @"it" : @"them"];
    dispatch_async(dispatch_get_main_queue(), ^{ [self emitConsole:waiting]; });
    self.waitingForPorts = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSNumber *> *busy = busyPorts();
        for (int i = 0; i < 90 && busy.count > 0; i++) {
            if (!weakSelf.waitingForPorts) break;
            sleep(1);
            busy = busyPorts();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            BOOL cancelled = !strongSelf.waitingForPorts;
            strongSelf.waitingForPorts = NO;
            if (cancelled) {
                [strongSelf finishServerRunWithCode:0];
            } else if (busy.count > 0) {
                [strongSelf emitConsole:[NSString stringWithFormat:@"%@ %@ still in use. Close whatever is using %@ (or restart the device) and try again.\n",
                                         busy.count == 1 ? @"Port" : @"Ports", [[busy valueForKey:@"stringValue"] componentsJoinedByString:@" and "],
                                         busy.count == 1 ? @"it" : @"them"]];
                [strongSelf finishServerRunWithCode:1];
            } else {
                [strongSelf runInWorker:job];
            }
        });
    });
}

- (void)runInWorker:(NSDictionary *)job {
    self.activeRunInProcess = NO;
    self.stopPending = NO;
    __weak typeof(self) weakSelf = self;
    __block __weak JessiWorker *weakWorker = nil;
    JessiWorker *worker = [JessiWorkerHost launchJob:job needsJIT:YES onLog:^(NSString *line) {
        [weakSelf emitConsole:line];
    } onEvent:^(NSDictionary *event) {
        [weakSelf handleWorkerEvent:event worker:weakWorker];
    } onExit:^(int code, NSString *problem) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.activeWorker == weakWorker) strongSelf.activeWorker = nil;
        if (problem) [strongSelf emitConsole:[NSString stringWithFormat:@"\n%@\n", problem]];
        if ([job[@"type"] isEqual:@"pumpkin"]) [strongSelf explainPumpkinExitCode:code];
        if (code == 240 && problem && [strongSelf.delegate respondsToSelector:@selector(serverServiceDidFailToEnableJIT:)]) {
            [strongSelf.delegate serverServiceDidFailToEnableJIT:problem];
        }
        [strongSelf finishServerRunWithCode:code];
    }];
    weakWorker = worker;
    self.activeWorker = worker;
}

- (void)handleWorkerEvent:(NSDictionary *)event worker:(JessiWorker *)worker {
    NSString *name = event[@"event"];
    if ([name isEqualToString:@"error"]) {
        [self emitConsole:[NSString stringWithFormat:@"\n%@\n", event[@"message"]]];
    } else if ([name isEqualToString:@"pumpkin-prompt"]) {
        NSNumber *promptID = event[@"id"];
        jessi_present_pumpkin_permission_prompt(event[@"plugin"] ?: @"", event[@"version"] ?: @"", event[@"permissions"] ?: @"", ^(int answer) {
            [worker send:@{@"cmd": @"prompt-reply", @"id": promptID ?: @0, @"answer": @(answer)}];
        });
    }
}

- (void)explainPumpkinExitCode:(int)code {
    if (code == JessiPumpkinErrAlreadyStarted) {
        [self emitConsole:@"\nPumpkin can only run once per app launch. Fully close JESSI and reopen it to start this server again.\n"];
    } else if (code == JessiPumpkinErrBadDirectory) {
        [self emitConsole:@"\nPumpkin could not open the server folder.\n"];
    } else if (code == JessiPumpkinErrRuntime) {
        [self emitConsole:@"\nPumpkin crashed. Check jessi-stdio.log in the server folder for details.\n"];
    }
}

- (BOOL)isPumpkinServerDir:(NSString *)dir {
    return dir.length > 0 && jessi_server_dir_is_pumpkin(dir);
}

- (BOOL)isPumpkinServerNamed:(NSString *)serverName {
    if (serverName.length == 0) return NO;
    return jessi_server_dir_is_pumpkin([self.serversRoot stringByAppendingPathComponent:serverName]);
}

- (NSArray<NSString *> *)availableServerFolders {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:self.serversRoot error:nil] ?: @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in items) {
        NSString *p = [self.serversRoot stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            [out addObject:name];
        }
    }
    [out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return out;
}

- (void)emitConsole:(NSString *)text {
    if (!text) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.console appendString:text];
        [self.delegate serverServiceDidUpdateConsole:self.console];
    });
}

- (NSString *)findJarInServerDir:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];

    for (NSString *name in items) {
        if ([name.lowercaseString isEqualToString:@"server.jar"]) {
            return [dir stringByAppendingPathComponent:name];
        }
    }

    for (NSString *name in items) {
        if ([[name pathExtension].lowercaseString isEqualToString:@"jar"]) {
            return [dir stringByAppendingPathComponent:name];
        }
    }

    return nil;
}

- (NSString *)rconPasswordForDir:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *rconPassPath = [dir stringByAppendingPathComponent:@".jessi_rcon_password"]; 
    NSString *pw = nil;
    if ([fm fileExistsAtPath:rconPassPath]) {
        pw = [[NSString stringWithContentsOfFile:rconPassPath encoding:NSUTF8StringEncoding error:nil]
              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (pw.length == 0) {
        static NSString *alphabet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        NSMutableString *s = [NSMutableString stringWithCapacity:24];
        for (int i = 0; i < 24; i++) {
            u_int32_t idx = arc4random_uniform((u_int32_t)alphabet.length);
            [s appendFormat:@"%C", [alphabet characterAtIndex:idx]];
        }
        pw = s;
        [pw writeToFile:rconPassPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return pw;
}

- (void)configureServerFilesInDir:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *pw = [self rconPasswordForDir:dir];
    self.activeServerDir = dir;
    self.activeRconPassword = pw;

    NSString *propertiesPath = [dir stringByAppendingPathComponent:@"server.properties"]; 
    NSMutableDictionary<NSString *, NSString *> *kv = [jessi_read_properties(propertiesPath) mutableCopy];

    kv[@"server-ip"] = @"";
    if (!kv[@"server-port"].length) kv[@"server-port"] = [NSString stringWithFormat:@"%d", JessiDefaultGamePort];
    self.activeRconPort = jessi_free_local_port(jessi_port_value(kv[@"rcon.port"], JessiDefaultRconPort));
    g_activeGamePort = jessi_port_value(kv[@"server-port"], JessiDefaultGamePort);

    kv[@"enable-rcon"] = @"true";
    kv[@"rcon.port"] = [NSString stringWithFormat:@"%d", self.activeRconPort];
    kv[@"rcon.password"] = pw;

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# Managed by JESSI\n"]; 
    for (NSString *k in [[kv allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        [out appendFormat:@"%@=%@\n", k, kv[k] ?: @""]; 
    }
    [out writeToFile:propertiesPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *eulaPath = [dir stringByAppendingPathComponent:@"eula.txt"]; 
    if (![fm fileExistsAtPath:eulaPath]) {
        [@"# https://aka.ms/MinecraftEULA\neula=true\n" writeToFile:eulaPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSString *eulaContent = [NSString stringWithContentsOfFile:eulaPath encoding:NSUTF8StringEncoding error:nil];
        if ([eulaContent containsString:@"eula=false"]) {
            eulaContent = [eulaContent stringByReplacingOccurrencesOfString:@"eula=false" withString:@"eula=true"];
            [eulaContent writeToFile:eulaPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

- (void)configurePumpkinFilesInDir:(NSString *)dir {
    NSString *pw = [self rconPasswordForDir:dir];
    self.activeServerDir = dir;
    self.activeRconPassword = pw;

    NSString *configPath = [dir stringByAppendingPathComponent:@"pumpkin.toml"];
    NSString *toml = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    self.activeRconPort = jessi_free_local_port(jessi_port_value(jessi_toml_get_value(toml, @"networking.rcon", @"address"), JessiDefaultRconPort));
    g_activeGamePort = jessi_port_value(jessi_toml_get_value(toml, @"networking.java", @"address"), JessiDefaultGamePort);
    toml = jessi_toml_set_values(toml, @"networking.rcon", @{
        @"enabled": @"true",
        @"address": [NSString stringWithFormat:@"\"127.0.0.1:%d\"", self.activeRconPort],
        @"password": [NSString stringWithFormat:@"\"%@\"", pw],
    });
    [toml writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)startTailingLatestLogInDir:(NSString *)dir {
    if (self.logTimer) {
        dispatch_source_cancel(self.logTimer);
        self.logTimer = nil;
    }
    self.logOffset = 0;

    self.stdioOffset = 0;

    NSString *logPath = [[dir stringByAppendingPathComponent:@"logs"] stringByAppendingPathComponent:@"latest.log"]; 
    NSString *stdioPath = [dir stringByAppendingPathComponent:@"jessi-stdio.log"]; 

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.logQueue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(250 * NSEC_PER_MSEC), (uint64_t)(50 * NSEC_PER_MSEC));

    __unsafe_unretained typeof(self) weakSelf = self;
    self.readNewLogOutput = ^(BOOL force) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || (!force && !strongSelf.isRunning)) return;

        NSFileManager *fm = [NSFileManager defaultManager];

        BOOL hasLatest = [fm fileExistsAtPath:logPath];
        NSString *pathToTail = hasLatest ? logPath : stdioPath;
        off_t *offsetPtr = hasLatest ? &strongSelf->_logOffset : &strongSelf->_stdioOffset;

        if (![fm fileExistsAtPath:pathToTail]) return;

        NSDictionary *attrs = [fm attributesOfItemAtPath:pathToTail error:nil];
        unsigned long long size = [attrs fileSize];
        if ((unsigned long long)(*offsetPtr) > size) *offsetPtr = 0;
        if ((unsigned long long)(*offsetPtr) == size) return;

        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:pathToTail];
        if (!fh) return;
        @try {
            [fh seekToFileOffset:(unsigned long long)(*offsetPtr)];
            NSData *data = [fh readDataToEndOfFile];
            *offsetPtr = (off_t)[fh offsetInFile];

            if (data.length) {
                NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (s.length) {
                    if (hasLatest) {
                        NSMutableArray *filteredLines = [NSMutableArray array];
                        for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
                            if ([line containsString:@"RCON"] ||
                                [line containsString:@"Rcon"] ||
                                [line containsString:@"remote control"]) {
                                continue;
                            }
                            [filteredLines addObject:line];
                        }
                        NSString *filtered = [filteredLines componentsJoinedByString:@"\n"];
                        if (filtered.length) [strongSelf emitConsole:filtered];
                    } else {
                        [strongSelf emitConsole:s];
                    }
                }
            }
        } @catch (__unused NSException *e) {
        }
        [fh closeFile];
    };
    void (^readNewLogOutput)(BOOL) = self.readNewLogOutput;
    dispatch_source_set_event_handler(timer, ^{ readNewLogOutput(NO); });

    dispatch_resume(timer);
    self.logTimer = timer;
}

static BOOL jessi_write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, p + off, len - off);
        if (n <= 0) return NO;
        off += (size_t)n;
    }
    return YES;
}

static BOOL jessi_read_all(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, p + off, len - off);
        if (n <= 0) return NO;
        off += (size_t)n;
    }
    return YES;
}

- (BOOL)sendRcon:(NSString *)command {
    if (command.length == 0) return NO;
    if (self.activeRconPassword.length == 0) return NO;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)self.activeRconPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NO;
    }

    int32_t reqId = 0x12345678;
    NSData *(^packet)(int32_t, int32_t, NSString *) = ^NSData *(int32_t pid, int32_t type, NSString *payload) {
        NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        int32_t length = (int32_t)(4 + 4 + payloadData.length + 2);
        NSMutableData *d = [NSMutableData dataWithCapacity:(NSUInteger)length + 4];
        [d appendBytes:&length length:4];
        [d appendBytes:&pid length:4];
        [d appendBytes:&type length:4];
        [d appendData:payloadData];
        uint8_t nul[2] = {0, 0};
        [d appendBytes:nul length:2];
        return d;
    };

    NSData *auth = packet(reqId, 3, self.activeRconPassword);
    if (!jessi_write_all(fd, auth.bytes, auth.length)) { close(fd); return NO; }

    int32_t respLen = 0;
    if (!jessi_read_all(fd, &respLen, 4)) { close(fd); return NO; }
    if (respLen < 10 || respLen > 4096) { close(fd); return NO; }
    NSMutableData *resp = [NSMutableData dataWithLength:(NSUInteger)respLen];
    if (!jessi_read_all(fd, resp.mutableBytes, (size_t)respLen)) { close(fd); return NO; }
    int32_t respId = 0;
    memcpy(&respId, resp.bytes, 4);
    if (respId == -1) { close(fd); return NO; }

    NSData *cmd = packet(reqId + 1, 2, command);
    if (!jessi_write_all(fd, cmd.bytes, cmd.length)) { close(fd); return NO; }

    NSMutableString *responseText = [NSMutableString string];
    while (1) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 300000;

        int ready = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (ready <= 0) break;

        int32_t outLen = 0;
        ssize_t n = recv(fd, &outLen, 4, MSG_WAITALL);
        if (n != 4) break;
        if (outLen < 10 || outLen > 65536) break;

        NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)outLen];
        n = recv(fd, out.mutableBytes, (size_t)outLen, MSG_WAITALL);
        if (n != outLen) break;

        int32_t outId = 0;
        memcpy(&outId, out.bytes, 4);
        if (outId == -1) break;

        NSUInteger payloadLen = (NSUInteger)outLen - 10;
        if (payloadLen == 0) break;

        NSData *payloadData = [out subdataWithRange:NSMakeRange(8, payloadLen)];
        NSString *payload = [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding];
        if (payload.length) {
            [responseText appendString:payload];
        }
    }

    if (responseText.length > 0) {
        if (![responseText hasSuffix:@"\n"]) {
            [responseText appendString:@"\n"]; 
        }
        [self emitConsole:responseText];
    }

    close(fd);
    return YES;
}

- (void)startServerNamed:(NSString *)serverName {
    [self startServerNamed:serverName withJavaVersion:nil];
}

- (void)startServerNamed:(NSString *)serverName withJavaVersion:(nullable NSString *)javaVersionOverride {
    @synchronized (self) {
        if (self.isRunning) {
            [self emitConsole:@"Server already running.\n"];
            return;
        }
        self.running = YES;
    }

    NSString *dir = [self.serversRoot stringByAppendingPathComponent:serverName];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *consoleLogPath = [dir stringByAppendingPathComponent:@"console.log"]; 
    NSString *stdioLogPath = [dir stringByAppendingPathComponent:@"jessi-stdio.log"]; 
    if ([fm fileExistsAtPath:consoleLogPath]) {
        [fm removeItemAtPath:consoleLogPath error:nil];
    }
    if ([fm fileExistsAtPath:stdioLogPath]) {
        [fm removeItemAtPath:stdioLogPath error:nil];
    }

    if (jessi_server_dir_is_pumpkin(dir)) {
        [self startPumpkinServerNamed:serverName inDir:dir];
        return;
    }

    NSString *launchArgsPath = [dir stringByAppendingPathComponent:@"jessi-launch-args.txt"]; 
    BOOL hasLaunchArgs = [fm fileExistsAtPath:launchArgsPath];

    NSString *jar = nil;
    if (hasLaunchArgs) {
        jar = [dir stringByAppendingPathComponent:@"server.jar"]; 
    } else {
        jar = [self findJarInServerDir:dir];
        if (!jar) {
            [self emitConsole:@"No .jar found in this server folder. Put your server jar in the folder (preferably named server.jar).\n"];
            self.running = NO;
            return;
        }
    }

    [self configureServerFilesInDir:dir];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.console setString:@""]; 
        [self emitConsole:[NSString stringWithFormat:@"Starting server: %@\n", serverName]];
        [self emitConsole:[NSString stringWithFormat:@"Jar: %@\n", jar.lastPathComponent]];
        [self emitConsole:[NSString stringWithFormat:@"Working dir: %@\n", dir]];
    });

    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverServiceDidChangeRunning:YES]; });

    [self startTailingLatestLogInDir:dir];

    JessiSettings *settings = [JessiSettings shared];
    NSString *javaVersion = javaVersionOverride ?: settings.javaVersion ?: @"8";

    if (!javaVersionOverride) {
        NSString *configPath = [dir stringByAppendingPathComponent:@"jessiserverconfig.json"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
            @try {
                NSData *data = [NSData dataWithContentsOfFile:configPath];
                if (data) {
                    NSDictionary *config = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSString *mcVersion = config[@"minecraftVersion"];
                    NSString *configJava = config[@"javaVersion"];
                    if ([configJava isKindOfClass:[NSString class]] && configJava.length) {
                        javaVersion = configJava;
                    } else if (mcVersion.length) {
                        javaVersion = jessi_recommended_java_version(mcVersion);
                    }
                }
            } @catch (id ex) {
            }
        }
    }

    [self beginBackgroundTaskIfNeeded];

    if ([JessiWorkerHost shouldUseWorkers]) {
        [self runInWorkerWhenPortsAreFree:@{@"type": @"server", @"jar": jar, @"javaVersion": javaVersion, @"dir": dir, @"rconPort": @(self.activeRconPort)}];
        return;
    }

    BOOL spawnsProcess = jessi_is_running_on_macos() ||
                         (jessi_has_trollstore_privileges() && !settings.disableSeparateJVMProcessOnTrollStore);
    self.activeRunInProcess = !spawnsProcess;

    dispatch_async(self.runQueue, ^{
        char *argv0 = strdup("--server");
        char *argv1 = strdup([jar fileSystemRepresentation]);
        char *argv2 = strdup([javaVersion UTF8String]);
        char *argv3 = strdup([dir fileSystemRepresentation]);
        char *argvv[] = { argv0, argv1, argv2, argv3, NULL };

        int code = 0;
        @try {
            BOOL shouldUseSeparateProcess = jessi_is_running_on_macos() ||
                                           (jessi_has_trollstore_privileges() && !settings.disableSeparateJVMProcessOnTrollStore);
            if (shouldUseSeparateProcess) {
                pid_t pid;
                NSString *executablePath = [[NSBundle mainBundle] executablePath];
                char *execPathC = strdup([executablePath fileSystemRepresentation]);
                char *spawnArgv[] = { execPathC, argv0, argv1, argv2, argv3, NULL };
                
                extern char **environ;
                
                int ret = posix_spawn(&pid, execPathC, NULL, NULL, spawnArgv, environ);
                
                if (ret == 0) {
                    NSString *pidPath = jessi_server_pid_file_path(dir);
                    NSString *pidText = [NSString stringWithFormat:@"%d\n", (int)pid];
                    [pidText writeToFile:pidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

                    int status;
                    waitpid(pid, &status, 0);

                    [[NSFileManager defaultManager] removeItemAtPath:pidPath error:nil];

                    if (WIFEXITED(status)) {
                        code = WEXITSTATUS(status);
                    } else {
                        code = 252;
                        if (WIFSIGNALED(status)) {
                            [self emitConsole:[NSString stringWithFormat:@"\nJVM process terminated by signal: %d\n", WTERMSIG(status)]];
                        } else if (WIFSTOPPED(status)) {
                            [self emitConsole:[NSString stringWithFormat:@"\nJVM process stopped by signal: %d\n", WSTOPSIG(status)]];
                        } else {
                            [self emitConsole:[NSString stringWithFormat:@"\nJVM process ended with wait status: %d\n", status]];
                        }
                    }
                } else {
                    code = 253;
                    [self emitConsole:[NSString stringWithFormat:@"\nFailed to spawn JVM process: %s\n", strerror(ret)]];
                }
                free(execPathC);
            } else {
                code = jessi_server_main(4, argvv);
            }
        } @catch (NSException *e) {
            code = 251;
            [self emitConsole:[NSString stringWithFormat:@"\nJVM threw exception: %@\n%@\n", e.reason ?: @"(no reason)", e.callStackSymbols ?: @[]]];
        }

        free(argv0); free(argv1); free(argv2); free(argv3);

        [self finishServerRunWithCode:code];
    });
}

- (void)beginBackgroundTaskIfNeeded {
#if !(TARGET_OS_OSX && !TARGET_OS_MACCATALYST)
    if ([JessiSettings shared].runInBackground) {
        self.bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
            self.bgTask = UIBackgroundTaskInvalid;
        }];
    }
#endif
}

- (void)finishServerRunWithCode:(int)code {
    self.running = NO;
    g_activeGamePort = 0;
    if (self.logTimer) {
        void (^readNewLogOutput)(BOOL) = self.readNewLogOutput;
        if (readNewLogOutput) dispatch_sync(self.logQueue, ^{ readNewLogOutput(YES); });
        dispatch_source_cancel(self.logTimer);
        self.logTimer = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self emitConsole:[NSString stringWithFormat:@"\nServer exited with code: %d\n", code]];
        [self.delegate serverServiceDidChangeRunning:NO];

#if !(TARGET_OS_OSX && !TARGET_OS_MACCATALYST)
        if (self.bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
            self.bgTask = UIBackgroundTaskInvalid;
        }
#endif
    });
}

- (void)startPumpkinServerNamed:(NSString *)serverName inDir:(NSString *)dir {
    NSString *libraryPath = [dir stringByAppendingPathComponent:JessiPumpkinLibraryFileName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:libraryPath]) {
        [self emitConsole:[NSString stringWithFormat:@"%@ is missing from this server folder. Create the server again to download it.\n", JessiPumpkinLibraryFileName]];
        self.running = NO;
        return;
    }

    [self configurePumpkinFilesInDir:dir];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.console setString:@""];
        [self emitConsole:[NSString stringWithFormat:@"Starting server: %@\n", serverName]];
        [self emitConsole:@"Software: Pumpkin\n"];
        [self emitConsole:[NSString stringWithFormat:@"Working dir: %@\n", dir]];
    });

    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverServiceDidChangeRunning:YES]; });

    [self startTailingLatestLogInDir:dir];
    [self beginBackgroundTaskIfNeeded];

    if ([JessiWorkerHost shouldUseWorkers]) {
        [self runInWorkerWhenPortsAreFree:@{@"type": @"pumpkin", @"library": libraryPath, @"dir": dir}];
        return;
    }

    self.activeRunInProcess = !jessi_is_running_on_macos();
    dispatch_async(self.runQueue, ^{
        int code = [self runPumpkinLibraryAtPath:libraryPath inDir:dir];
        [self finishServerRunWithCode:code];
    });
}

- (int)runPumpkinLibraryAtPath:(NSString *)libraryPath inDir:(NSString *)dir {
    void *handle = jessi_dlopen_with_dyld_bypass(libraryPath.fileSystemRepresentation, RTLD_NOW);
    if (!handle) {
        const char *err = dlerror();
        NSString *hint = jessi_check_jit_enabled() ? @"" : @"\nEnable JIT first; the library is ad-hoc signed and can only be loaded with JIT enabled.";
        [self emitConsole:[NSString stringWithFormat:@"\nFailed to load %@: %s%@\n", JessiPumpkinLibraryFileName, err ?: "unknown error", hint]];
        return 254;
    }

    JessiPumpkinRunFn run = (JessiPumpkinRunFn)dlsym(handle, "pumpkin_run");
    JessiPumpkinStopFn stop = (JessiPumpkinStopFn)dlsym(handle, "pumpkin_stop");
    if (!run || !stop) {
        [self emitConsole:[NSString stringWithFormat:@"\n%@ does not export pumpkin_run/pumpkin_stop.\n", JessiPumpkinLibraryFileName]];
        return 254;
    }

    JessiPumpkinSetPromptFn setPrompt = (JessiPumpkinSetPromptFn)dlsym(handle, "pumpkin_set_permission_prompt");
    if (setPrompt) setPrompt(jessi_pumpkin_permission_prompt);

    jessi_redirect_stdio_to([dir stringByAppendingPathComponent:@"jessi-stdio.log"]);

    @synchronized ([JessiServerService class]) { g_pumpkinStop = stop; }
    int code = run(dir.fileSystemRepresentation);
    @synchronized ([JessiServerService class]) { g_pumpkinStop = NULL; }

    [self explainPumpkinExitCode:code];
    return code;
}

- (void)stopServer {
    if (!self.isRunning) return;
    if (self.waitingForPorts) {
        self.waitingForPorts = NO;
        return;
    }
    JessiWorker *worker = self.activeWorker;
    if (worker && [self isPumpkinServerDir:self.activeServerDir]) {
        [worker send:@{@"cmd": @"stop"}];
        return;
    }
    JessiPumpkinStopFn pumpkinStop;
    @synchronized ([JessiServerService class]) { pumpkinStop = g_pumpkinStop; }
    if (pumpkinStop) {
        pumpkinStop();
        return;
    }
    if ([self sendRcon:@"stop"] || !worker || self.stopPending) return;
    self.stopPending = YES;
    [self emitConsole:@"\nThe server is still starting; it will stop as soon as it's ready.\n"];
    [self retryStopForWorker:worker];
}

- (void)retryStopForWorker:(JessiWorker *)worker {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isRunning || strongSelf.activeWorker != worker) {
            strongSelf.stopPending = NO;
            return;
        }
        if ([strongSelf sendRcon:@"stop"]) {
            strongSelf.stopPending = NO;
        } else {
            [strongSelf retryStopForWorker:worker];
        }
    });
}

- (void)clearConsole {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.console setString:@"Console cleared.\n"];
        [self.delegate serverServiceDidUpdateConsole:self.console];
    });
}

- (NSString *)cleanupStaleJVMProcessesOnMac {
    if (!jessi_is_running_on_macos()) {
        return @"Cleanup is only available on macOS builds.";
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self serversRoot];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];

    NSMutableSet<NSNumber *> *targetPIDs = [NSMutableSet set];
    NSMutableArray<NSString *> *pidFiles = [NSMutableArray array];

    for (NSString *name in entries) {
        NSString *dir = [root stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;

        NSString *pidFile = jessi_server_pid_file_path(dir);
        [pidFiles addObject:pidFile];

        NSString *pidText = [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:nil]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (pidText.length) {
            pid_t pid = (pid_t)[pidText intValue];
            if (pid > 1) [targetPIDs addObject:@(pid)];
        }
    }

    NSMutableSet<NSNumber *> *ports = [NSMutableSet setWithObjects:@(JessiDefaultGamePort), @(JessiDefaultRconPort), nil];
    for (NSString *name in entries) {
        [ports addObjectsFromArray:jessi_server_ports_in_dir([root stringByAppendingPathComponent:name])];
    }
    for (NSNumber *port in ports) {
        [targetPIDs unionSet:[jessi_pids_listening_on_port(port.intValue) mutableCopy]];
    }

    int checked = 0;
    int killed = 0;
    for (NSNumber *n in targetPIDs) {
        pid_t pid = (pid_t)n.intValue;
        checked++;

        NSString *cmd = jessi_command_for_pid(pid);
        if (cmd.length > 0 && !jessi_looks_like_jessi_java(cmd)) {
            continue;
        }

        if (jessi_terminate_pid(pid)) {
            killed++;
        }
    }

    for (NSString *pidFile in pidFiles) {
        [fm removeItemAtPath:pidFile error:nil];
    }

    if (killed > 0) {
        return [NSString stringWithFormat:@"Stopped %d stale JVM process(es). The server ports should now be clear.", killed];
    }
    if (checked > 0) {
        return @"No stale JESSI JVM process needed termination.";
    }
    return @"No stale JESSI JVM processes found.";
}

- (void)importServerJarFromURL:(NSURL *)url serverNameHint:(NSString *)nameHint completion:(void (^)(NSError * _Nullable, NSString * _Nullable))completion {
    if (!url) {
        if (completion) completion([NSError errorWithDomain:@"Jessi" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Missing URL"}], nil);
        return;
    }

    NSString *serverName = nameHint.length ? nameHint : url.lastPathComponent.stringByDeletingPathExtension;
    serverName = [serverName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (serverName.length == 0) serverName = @"Server";

    NSString *dir = [self.serversRoot stringByAppendingPathComponent:serverName];
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([fm fileExistsAtPath:dir]) {
        for (int i = 2; i < 1000; i++) {
            NSString *candidate = [self.serversRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d", serverName, i]];
            if (![fm fileExistsAtPath:candidate]) {
                dir = candidate;
                serverName = [candidate lastPathComponent];
                break;
            }
        }
    }

    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:@"server.jar"]; 

    NSFileCoordinator *coord = [[NSFileCoordinator alloc] init];
    __block NSError *coordErr = nil;
    __block NSError *copyErr = nil;
    __block BOOL ok = NO;

    [coord coordinateReadingItemAtURL:url options:0 error:&coordErr byAccessor:^(NSURL * _Nonnull newURL) {
        NSError *localErr = nil;
        [fm removeItemAtPath:dest error:nil];
        ok = [fm copyItemAtURL:newURL toURL:[NSURL fileURLWithPath:dest] error:&localErr];
        copyErr = localErr;
    }];

    NSError *finalErr = copyErr ?: coordErr;
    if (!ok && !finalErr) finalErr = [NSError errorWithDomain:@"Jessi" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Copy failed"}];

    if (completion) completion(finalErr, finalErr ? nil : serverName);
}

@end
