static NSDictionary *transferableClipboard(NSPasteboard *board, BOOL automatic) {
    if ((automatic && ([board.types containsObject:@"org.nspasteboard.ConcealedType"] ||
                       [board.types containsObject:@"org.nspasteboard.TransientType"])) ||
        [board canReadObjectForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}]) return nil;
    NSData *png = [board dataForType:NSPasteboardTypePNG];
    if (!png) {
        NSData *tiff = [board dataForType:NSPasteboardTypeTIFF];
        if (tiff.length && tiff.length <= (24 << 20)) {
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:tiff];
            if (bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 &&
                (double)bitmap.pixelsWide * bitmap.pixelsHigh <= 16000000) {
                png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            }
        }
    }
    if (png.length && png.length <= (9 << 20)) return @{@"png": [png base64EncodedStringWithOptions:0]};
    NSString *text = [board stringForType:NSPasteboardTypeString];
    if (text && [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= (2 << 20)) return @{@"text": text};
    return nil;
}

static void clipboardNotice(NSString *message) {
    if (!showEmbeddedControls || !message.length) return;
    showEmbeddedControls([@"notice:" stringByAppendingString:message].UTF8String);
}

static NSArray<NSURL *> *hostClipboardFiles(NSPasteboard *board) {
    if ([board.types containsObject:@"org.nspasteboard.ConcealedType"] ||
        [board.types containsObject:@"org.nspasteboard.TransientType"]) return nil;
    NSArray<NSURL *> *urls = [board readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    return urls.count ? urls : nil;
}

// Files copied on the Mac reach the guest only when the selection is small
// enough to stage quickly; larger moves go through the explicit upload.
static NSString *clipboardFilesProblem(NSArray<NSURL *> *urls) {
    if (urls.count > 100) return @"一次最多复制 100 项到客机";
    NSFileManager *fm = NSFileManager.defaultManager;
    long long total = 0;
    NSUInteger entries = 0;
    for (NSURL *url in urls) {
        if (!url.isFileURL || (url.host.length && ![url.host isEqualToString:@"localhost"])) return @"只能复制本机文件";
        NSNumber *directory = nil;
        [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:NULL];
        id<NSFastEnumeration> items = directory.boolValue ?
            [fm enumeratorAtURL:url includingPropertiesForKeys:@[NSURLFileSizeKey] options:0 errorHandler:nil] : @[url];
        for (NSURL *item in items) {
            if (++entries > 20000) return @"复制的文件数量过多，请压缩后再复制到客机";
            NSNumber *size = nil;
            [item getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
            total += size.longLongValue;
            if (total > (1LL << 30)) return @"复制的文件超过 1 GB，未自动同步。可把文件拖到客机画面上传";
        }
    }
    return nil;
}

// Runs the bundled backend's clipboard file helper; arguments never carry
// file contents, only host paths or transient selection identities.
static NSDictionary *clipboardFilesCommand(NSArray<NSString *> *args, NSString **failure) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSBundle.mainBundle URLForResource:@"vmac" withExtension:nil];
    if (!task.executableURL) { if (failure) *failure = @"缺少 VMac 后台组件"; return nil; }
    task.arguments = [@[@"clipboard-files", @"--json"] arrayByAddingObjectsFromArray:args];
    NSPipe *output = NSPipe.pipe;
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) { if (failure) *failure = @"无法启动剪贴板文件传递"; return nil; }
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    id value = data.length <= (1 << 20) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *result = [value isKindOfClass:NSDictionary.class] ? value : nil;
    if (task.terminationStatus != 0 || !result) {
        NSString *message = [result[@"message"] isKindOfClass:NSString.class] ? result[@"message"] : nil;
        if (failure) *failure = message ?: @"剪贴板文件传递失败，请重新复制";
        return nil;
    }
    return result;
}

static NSDictionary *clipboardCacheCommand(NSString *action, NSString *cache) {
    NSData *request = [NSJSONSerialization dataWithJSONObject:@{@"action":action, @"cache_id":cache ?: @""} options:0 error:NULL];
    NSString *text = request ? [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] : nil;
    return text ? clipboardFilesCommand(@[@"cache", text], NULL) : nil;
}

// Both default to on; the File menu stores an explicit choice.
static BOOL vmacPreference(NSString *key) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key] == nil || [defaults boolForKey:key];
}
static BOOL clipboardSharingEnabled(void) { return vmacPreference(@"vmac.shareClipboardContent"); }
static BOOL hostInputMethodEnabled(void) { return vmacPreference(@"vmac.hostInputMethod"); }

@interface CageDesktopClipboard : NSObject
@property(nonatomic, readonly) BOOL canTypeText;
- (void)setDesktopVisible:(BOOL)visible;
// Puts text on the guest clipboard; ready runs once the guest can paste it.
- (void)typeText:(NSString *)text ready:(void (^)(BOOL ok))ready;
@end

@implementation CageDesktopClipboard {
    NSTimer *_timer;
    NSTask *_task;
    NSFileHandle *_writer;
    dispatch_queue_t _outgoing;
    NSInteger _hostRevision;
    NSInteger _serial;
    NSInteger _pendingSerial;
    BOOL _connected;
    BOOL _transferring;
    NSTimeInterval _retryAfter;
    NSTimeInterval _lastRequest;
    NSTimeInterval _lastCollect;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_caches;
    NSMutableDictionary<NSString *, NSNumber *> *_unreferenced;
    BOOL _filesEnabled;
    BOOL _typingEnabled;
    BOOL _subscribed;
    NSMutableArray<NSMutableDictionary *> *_typingQueue;
}
- (void)closeConnection {
    [_task.standardOutput fileHandleForReading].readabilityHandler = nil;
    if (_task.isRunning) [_task terminate];
    _task = nil;
    _writer = nil;
    _connected = NO;
    _pendingSerial = 0;
    _filesEnabled = NO;
    _typingEnabled = NO;
    _subscribed = NO;
    NSArray *abandoned = _typingQueue;
    _typingQueue = nil;
    for (NSDictionary *entry in abandoned) ((void (^)(BOOL))entry[@"ready"])(NO);
}
- (BOOL)canTypeText { return _connected && _typingEnabled; }
- (void)typeText:(NSString *)text ready:(void (^)(BOOL ok))ready {
    if (!self.canTypeText || !text.length) { ready(NO); return; }
    if (!_typingQueue) _typingQueue = [NSMutableArray array];
    [_typingQueue addObject:[@{@"text":text, @"ready":[ready copy], @"serial":@(++_serial)} mutableCopy]];
    if (_typingQueue.count == 1) [self sendTyping];
}
- (void)sendTyping {
    NSMutableDictionary *head = _typingQueue.firstObject;
    if (!head) return;
    head[@"sent"] = @(NSProcessInfo.processInfo.systemUptime);
    [self send:@{@"type_text":head[@"text"], @"serial":head[@"serial"]}];
}
- (void)typed:(NSInteger)serial {
    NSMutableDictionary *head = _typingQueue.firstObject;
    if (!head || [head[@"serial"] integerValue] != serial) return;
    [_typingQueue removeObjectAtIndex:0];
    ((void (^)(BOOL))head[@"ready"])(YES);
    // Give the focused guest app time to read the pasted text, then put the
    // user's own clipboard back. A later chunk supersedes this restore.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CageDesktopClipboard *client = weakSelf;
        if (client && client->_connected) [client send:@{@"restore_text":@(serial)}];
    });
    [self sendTyping];
}
- (void)setDesktopVisible:(BOOL)visible {
    BOOL enabled = clipboardSharingEnabled() || hostInputMethodEnabled();
    if (!visible || !enabled) {
        [_timer invalidate];
        _timer = nil;
        [self closeConnection];
        return;
    }
    // Reconnect when clipboard sharing was switched while connected.
    if (_connected && _subscribed != clipboardSharingEnabled()) [self closeConnection];
    if (_timer) return;
    _retryAfter = 0;
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer *timer) {
        [weakSelf tick];
    }];
    [self tick];
}
- (void)send:(NSDictionary *)contents {
    NSData *message = [NSJSONSerialization dataWithJSONObject:contents options:0 error:NULL];
    NSString *text = [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding];
    if (!text) return;
    NSData *frame = [NSJSONSerialization dataWithJSONObject:@{@"type":@"text", @"data":text} options:0 error:NULL];
    NSMutableData *line = [frame mutableCopy];
    [line appendBytes:"\n" length:1];
    NSFileHandle *writer = _writer;
    dispatch_async(_outgoing, ^{ [writer writeData:line error:NULL]; });
}
- (void)receive:(NSDictionary *)frame {
    NSString *text = frame[@"data"];
    if (![frame[@"type"] isEqual:@"text"] || ![text isKindOfClass:NSString.class]) return;
    id object = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![object isKindOfClass:NSDictionary.class]) return;
    NSDictionary *message = object;
    if (message[@"error"]) {
        [self closeConnection];
        return;
    }
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if ([message[@"hello"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *hello = message[@"hello"];
        if (![hello[@"os"] isEqual:@"darwin"] || ![hello[@"available"] boolValue]) {
            [self closeConnection];
            return;
        }
        _connected = YES;
        _filesEnabled = [hello[@"subscribe"] boolValue];
        _typingEnabled = [hello[@"type_text"] boolValue];
        _hostRevision = board.changeCount;
        _subscribed = clipboardSharingEnabled();
        if (_subscribed) [self send:@{@"subscribe":@YES}];
        return;
    }
    NSNumber *typed = message[@"typed"];
    if ([typed isKindOfClass:NSNumber.class]) { [self typed:typed.integerValue]; return; }
    NSNumber *ack = message[@"ack"];
    if ([ack isKindOfClass:NSNumber.class] && ack.integerValue == _pendingSerial) _pendingSerial = 0;
    if (!_connected || _pendingSerial || _transferring || board.changeCount != _hostRevision || !clipboardSharingEnabled()) return;
    if (message[@"files"]) {
        if ([message[@"files"] isKindOfClass:NSString.class]) [self receiveFiles:message[@"files"]];
        return;
    }
    NSString *value = message[@"text"], *encoded = message[@"png"];
    NSData *png = [encoded isKindOfClass:NSString.class] && encoded.length <= (12 << 20) ?
        [[NSData alloc] initWithBase64EncodedString:encoded options:0] : nil;
    BOOL validText = [value isKindOfClass:NSString.class] && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= (2 << 20);
    if (!png.length && !validText) return;
    [board clearContents];
    if (png.length) [board setData:png forType:NSPasteboardTypePNG];
    else [board setString:value forType:NSPasteboardTypeString];
    _hostRevision = board.changeCount;
}
- (void)connect {
    _retryAfter = NSProcessInfo.processInfo.systemUptime + 4;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSBundle.mainBundle URLForResource:@"vmac" withExtension:nil];
    if (!task.executableURL) return;
    task.arguments = @[@"agent", @"socket", @"/api/clipboard"];
    NSPipe *input = NSPipe.pipe, *output = NSPipe.pipe;
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return;
    _task = task;
    _lastRequest = NSProcessInfo.processInfo.systemUptime;
    _writer = input.fileHandleForWriting;
    fcntl(_writer.fileDescriptor, F_SETNOSIGPIPE, 1);
    _outgoing = dispatch_queue_create("net.vmac.clipboard.write", DISPATCH_QUEUE_SERIAL);
    NSMutableData *buffer = NSMutableData.data;
    __weak typeof(self) weakSelf = self;
    __weak NSTask *weakTask = task;
    output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *reader) {
        NSData *data = reader.availableData;
        if (!data.length || buffer.length + data.length > (32 << 20)) {
            reader.readabilityHandler = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                CageDesktopClipboard *client = weakSelf;
                if (client && client->_task == weakTask) [client closeConnection];
            });
            return;
        }
        [buffer appendData:data];
        while (buffer.length) {
            const void *start = buffer.bytes, *end = memchr(start, '\n', buffer.length);
            if (!end) break;
            NSUInteger length = (const char *)end - (const char *)start;
            NSData *line = [buffer subdataWithRange:NSMakeRange(0, length)];
            [buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
            id value = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            if (![value isKindOfClass:NSDictionary.class]) continue;
            dispatch_async(dispatch_get_main_queue(), ^{
                CageDesktopClipboard *client = weakSelf;
                if (client && client->_task == weakTask) [client receive:value];
            });
        }
    };
}
- (void)tick {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!_task) {
        if (now >= _retryAfter) [self connect];
        return;
    }
    NSNumber *typingSent = _typingQueue.firstObject[@"sent"];
    if (typingSent && now - typingSent.doubleValue > 3) { [self closeConnection]; return; }
    if (_transferring) return;
    if (!_connected || _pendingSerial) {
        if (now - _lastRequest > 12) [self closeConnection];
        return;
    }
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (now - _lastCollect > 5) { _lastCollect = now; [self collectCaches]; }
    NSInteger revision = board.changeCount;
    if (revision == _hostRevision || !clipboardSharingEnabled()) return;
    NSArray<NSURL *> *files = hostClipboardFiles(board);
    if (files && !_filesEnabled) { _hostRevision = revision; return; }
    if (files) {
        // Stage Mac files only once VMac is in front, so unrelated Finder
        // copies in other apps are not uploaded to the guest.
        if (!NSApp.isActive) return;
        _hostRevision = revision;
        [self sendFiles:files revision:revision];
        return;
    }
    NSMutableDictionary *contents = [transferableClipboard(board, YES) mutableCopy];
    if (board.changeCount != revision) return;
    _hostRevision = revision;
    if (!contents) return;
    _pendingSerial = ++_serial;
    _lastRequest = now;
    contents[@"serial"] = @(_pendingSerial);
    [self send:contents];
}
- (void)sendFiles:(NSArray<NSURL *> *)files revision:(NSInteger)revision {
    _transferring = YES;
    NSArray<NSString *> *paths = [files valueForKey:@"path"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = clipboardFilesProblem(files);
        NSDictionary *result = failure ? nil :
            clipboardFilesCommand([@[@"--connection", @"local", @"send"] arrayByAddingObjectsFromArray:paths], &failure);
        dispatch_async(dispatch_get_main_queue(), ^{
            CageDesktopClipboard *client = weakSelf;
            NSString *selection = [result[@"files"] isKindOfClass:NSString.class] ? result[@"files"] : nil;
            if (!client) return;
            client->_transferring = NO;
            if (!selection) { clipboardNotice(failure); return; }
            if (!client->_connected || NSPasteboard.generalPasteboard.changeCount != revision) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    clipboardFilesCommand(@[@"--connection", @"local", @"release", selection], NULL);
                });
                return;
            }
            client->_pendingSerial = ++client->_serial;
            client->_lastRequest = NSProcessInfo.processInfo.systemUptime;
            [client send:@{@"files":selection, @"serial":@(client->_pendingSerial)}];
        });
    });
}
- (void)receiveFiles:(NSString *)selection {
    _transferring = YES;
    NSInteger expected = NSPasteboard.generalPasteboard.changeCount;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = nil;
        NSDictionary *result = clipboardFilesCommand(@[@"--connection", @"local", @"receive", selection], &failure);
        // The local cache now holds the files; the guest snapshot can go.
        clipboardFilesCommand(@[@"--connection", @"local", @"release", selection], NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            CageDesktopClipboard *client = weakSelf;
            NSArray *paths = [result[@"paths"] isKindOfClass:NSArray.class] ? result[@"paths"] : nil;
            NSString *cache = [result[@"cache_id"] isKindOfClass:NSString.class] ? result[@"cache_id"] : @"";
            if (!client) return;
            client->_transferring = NO;
            if (!paths.count) { clipboardNotice(failure); return; }
            NSPasteboard *board = NSPasteboard.generalPasteboard;
            NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:paths.count];
            for (NSString *path in paths) if ([path isKindOfClass:NSString.class]) [urls addObject:[NSURL fileURLWithPath:path]];
            if (board.changeCount != expected || urls.count != paths.count) { [client releaseCache:cache]; return; }
            [board clearContents];
            if (![board writeObjects:urls]) { [client releaseCache:cache]; return; }
            client->_hostRevision = board.changeCount;
            if (cache.length) {
                client->_caches[cache] = paths;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ clipboardCacheCommand(@"publish", cache); });
            }
        });
    });
}
- (void)releaseCache:(NSString *)cache {
    if (!cache.length) return;
    [_caches removeObjectForKey:cache];
    [_unreferenced removeObjectForKey:cache];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ clipboardCacheCommand(@"release", cache); });
}
// Cached guest files stay on disk while the Mac clipboard refers to them, and
// for ten minutes afterwards so a Finder copy that is still running can finish.
- (void)collectCaches {
    if (!_caches) {
        _caches = [NSMutableDictionary dictionary];
        _unreferenced = [NSMutableDictionary dictionary];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSArray *selections = clipboardCacheCommand(@"list", nil)[@"selections"];
            dispatch_async(dispatch_get_main_queue(), ^{
                CageDesktopClipboard *client = weakSelf;
                if (!client || ![selections isKindOfClass:NSArray.class]) return;
                for (NSDictionary *selection in selections) {
                    if (![selection isKindOfClass:NSDictionary.class]) continue;
                    NSString *cache = selection[@"cache_id"];
                    NSArray *paths = selection[@"paths"];
                    if ([cache isKindOfClass:NSString.class] && [paths isKindOfClass:NSArray.class] && paths.count && !client->_caches[cache])
                        client->_caches[cache] = paths;
                }
            });
        });
        return;
    }
    NSArray<NSURL *> *current = [NSPasteboard.generalPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}] ?: @[];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (NSString *cache in _caches.allKeys) {
        NSString *first = _caches[cache].firstObject;
        if (![first isKindOfClass:NSString.class]) { [self releaseCache:cache]; continue; }
        NSString *root = first.stringByDeletingLastPathComponent.stringByStandardizingPath;
        BOOL referenced = NO;
        for (NSURL *url in current) {
            NSString *path = url.path.stringByStandardizingPath;
            if ([path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]) { referenced = YES; break; }
        }
        if (referenced) { [_unreferenced removeObjectForKey:cache]; continue; }
        NSNumber *since = _unreferenced[cache];
        if (!since) _unreferenced[cache] = @(now);
        else if (now - since.doubleValue > 600) [self releaseCache:cache];
    }
}
- (void)dealloc {
    [_timer invalidate];
    [self closeConnection];
}
@end
