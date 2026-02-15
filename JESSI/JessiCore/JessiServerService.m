#import "JessiServerService.h"

#import "JessiPaths.h"
#import "JessiSettings.h"

#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <sys/time.h>
#import <unistd.h>

extern int jessi_server_main(int argc, char *argv[]);

static NSString *const JessiServerRunningKey = @"jessi.server.running";
static NSString *const JessiServerRunningChanged = @"JessiServerRunningChanged";
static BOOL g_serverRunning = NO;

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
@end

@implementation JessiServerService

- (instancetype)init {
    self = [super init];
    if (self) {
        _console = [NSMutableString string];
        _runQueue = dispatch_queue_create("com.baconmania.jessi.run", DISPATCH_QUEUE_SERIAL);
        _logQueue = dispatch_queue_create("com.baconmania.jessi.log", DISPATCH_QUEUE_SERIAL);
        _activeRconPort = 25575;
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

- (void)configureServerFilesInDir:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

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

    self.activeServerDir = dir;
    self.activeRconPassword = pw;
    self.activeRconPort = 25575;

    NSString *propertiesPath = [dir stringByAppendingPathComponent:@"server.properties"]; 
    NSMutableDictionary<NSString *, NSString *> *kv = [NSMutableDictionary dictionary];
    if ([fm fileExistsAtPath:propertiesPath]) {
        NSString *content = [NSString stringWithContentsOfFile:propertiesPath encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            if (line.length == 0 || [line hasPrefix:@"#"]) continue;
            NSRange r = [line rangeOfString:@"="];
            if (r.location == NSNotFound) continue;
            NSString *k = [line substringToIndex:r.location];
            NSString *v = [line substringFromIndex:r.location + 1];
            if (k.length) kv[k] = v ?: @"";
        }
    }

    kv[@"server-ip"] = @"";
    if (!kv[@"server-port"]) kv[@"server-port"] = @"25565";

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

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isRunning) return;

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
    });

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
    if (self.isRunning) {
        [self emitConsole:@"Server already running.\n"]; 
        return;
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

    NSString *launchArgsPath = [dir stringByAppendingPathComponent:@"jessi-launch-args.txt"]; 
    BOOL hasLaunchArgs = [fm fileExistsAtPath:launchArgsPath];

    NSString *jar = nil;
    if (hasLaunchArgs) {
        jar = [dir stringByAppendingPathComponent:@"server.jar"]; 
    } else {
        jar = [self findJarInServerDir:dir];
        if (!jar) {
            [self emitConsole:@"No .jar found in this server folder. Put your server jar in the folder (preferably named server.jar).\n"]; 
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

    self.running = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverServiceDidChangeRunning:YES]; });

    [self startTailingLatestLogInDir:dir];

    JessiSettings *settings = [JessiSettings shared];
    NSString *javaVersion = settings.javaVersion ?: @"8";

    dispatch_async(self.runQueue, ^{
        char *argv0 = strdup("--server");
        char *argv1 = strdup([jar fileSystemRepresentation]);
        char *argv2 = strdup([javaVersion UTF8String]);
        char *argv3 = strdup([dir fileSystemRepresentation]);
        char *argvv[] = { argv0, argv1, argv2, argv3, NULL };

        int code = 0;
        @try {
            code = jessi_server_main(4, argvv);
        } @catch (NSException *e) {
            code = 251;
            [self emitConsole:[NSString stringWithFormat:@"\nJVM threw exception: %@\n%@\n", e.reason ?: @"(no reason)", e.callStackSymbols ?: @[]]];
        }

        free(argv0); free(argv1); free(argv2); free(argv3);

        self.running = NO;
        if (self.logTimer) {
            dispatch_source_cancel(self.logTimer);
            self.logTimer = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self emitConsole:[NSString stringWithFormat:@"\nServer exited with code: %d\n", code]];
            [self.delegate serverServiceDidChangeRunning:NO];
        });
    });
}

- (void)stopServer {
    if (!self.isRunning) return;
    [self sendRcon:@"stop"];
}

- (void)clearConsole {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.console setString:@"Console cleared.\n"];
        [self.delegate serverServiceDidUpdateConsole:self.console];
    });
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
