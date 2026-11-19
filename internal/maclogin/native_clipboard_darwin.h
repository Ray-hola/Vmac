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

@interface CageDesktopClipboard : NSObject
- (void)setDesktopVisible:(BOOL)visible;
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
    NSTimeInterval _retryAfter;
    NSTimeInterval _lastRequest;
}
- (void)closeConnection {
    [_task.standardOutput fileHandleForReading].readabilityHandler = nil;
    if (_task.isRunning) [_task terminate];
    _task = nil;
    _writer = nil;
    _connected = NO;
    _pendingSerial = 0;
}
- (void)setDesktopVisible:(BOOL)visible {
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"vmac.shareClipboardContent"];
    if (!visible || !enabled) {
        [_timer invalidate];
        _timer = nil;
        [self closeConnection];
        return;
    }
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
        _hostRevision = board.changeCount;
        [self send:@{@"subscribe":@YES}];
        return;
    }
    NSNumber *ack = message[@"ack"];
    if ([ack isKindOfClass:NSNumber.class] && ack.integerValue == _pendingSerial) _pendingSerial = 0;
    if (!_connected || _pendingSerial || board.changeCount != _hostRevision || message[@"files"]) return;
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
    if (!_connected || _pendingSerial) {
        if (now - _lastRequest > 12) [self closeConnection];
        return;
    }
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSInteger revision = board.changeCount;
    if (revision == _hostRevision) return;
    NSMutableDictionary *contents = [transferableClipboard(board, YES) mutableCopy];
    if (board.changeCount != revision) return;
    _hostRevision = revision;
    if (!contents) return;
    _pendingSerial = ++_serial;
    _lastRequest = now;
    contents[@"serial"] = @(_pendingSerial);
    [self send:contents];
}
- (void)dealloc {
    [_timer invalidate];
    [self closeConnection];
}
@end
