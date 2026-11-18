// The AppKit window belongs to the process that owns VZVirtualMachine.
@interface CageNativeVMWindow : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) NSView *pane;
@property(nonatomic, strong) VZVirtualMachineView *view;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL shuttingDown;
- (void)bringForward;
@end

@implementation CageNativeVMWindow
- (void)showNotice:(NSString *)message {
    if (showEmbeddedControls) {
        NSString *notice = [@"notice:" stringByAppendingString:message ?: @""];
        showEmbeddedControls(notice.UTF8String);
    }
}
- (void)bringForward {
    self.pane.hidden = NO;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.view];
}
- (void)showControls:(NSString *)reason {
    cageHideEmbeddedDesktop();
    if (showEmbeddedControls) showEmbeddedControls(reason.UTF8String);
}
- (IBAction)openControls:(id)sender {
    [self showControls:@"settings"];
}

- (void)runAgent:(NSArray<NSString *> *)args input:(NSData *)input
            done:(void (^)(NSDictionary *, NSString *))done {
    if (self.busy) return;
    self.busy = YES;
    [self showNotice:@"正在处理…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSBundle.mainBundle URLForResource:@"vmac" withExtension:nil]
            ?: [NSBundle.mainBundle URLForResource:@"cage" withExtension:nil];
        task.arguments = args;
        NSPipe *output = NSPipe.pipe;
        NSPipe *pipe = input ? NSPipe.pipe : nil;
        task.standardInput = pipe ?: NSFileHandle.fileHandleWithNullDevice;
        task.standardOutput = output;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSDictionary *reply = nil;
        if ([task launchAndReturnError:NULL]) {
            if (pipe) {
                [pipe.fileHandleForWriting writeData:input error:NULL];
                [pipe.fileHandleForWriting closeFile];
            }
            NSData *data = [output.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([decoded isKindOfClass:NSDictionary.class]) reply = decoded;
        }
        NSDictionary *result = reply[@"data"];
        if (![result isKindOfClass:NSDictionary.class]) result = nil;
        NSString *failure = reply[@"error"][@"message"];
        if (task.isRunning || !result || [reply[@"status"] isEqual:@"error"]) {
            if (!failure.length) failure = @"无法完成操作，请检查 VMac 与客机的连接";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self showNotice:failure ?: @""];
            if (done) done(result, failure);
            if (self.window.isKeyWindow && !self.pane.hidden) [self.window makeFirstResponder:self.view];
        });
    });
}
- (IBAction)recheck:(id)sender {
    [self runAgent:@[@"agent", @"call", @"network.check", @"--wait", @"90s"] input:nil
            done:^(NSDictionary *value, NSString *failure) {
        if (!failure) [self showNotice:@"联网检查通过"];
    }];
}
- (IBAction)restart:(id)sender {
    if (self.busy || self.window.attachedSheet) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"重启 macOS 客机？";
    alert.informativeText = @"请先保存客机中的工作。";
    [alert addButtonWithTitle:@"重启客机"];
    [alert addButtonWithTitle:@"取消"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [self showControls:@"restarting"];
        [self runAgent:@[@"agent", @"request", @"POST", @"/api/macos/restart"] input:nil
                done:^(NSDictionary *value, NSString *failure) {
            if (failure) [self bringForward];
        }];
    }];
}
- (IBAction)upload:(id)sender {
    if (self.busy || self.window.attachedSheet) return;
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.title = @"上传文件到客机";
    panel.message = @"文件将保存到客机的「下载 → VMac Uploads」。";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.resolvesAliases = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSURL *url = panel.URL;
        NSDictionary *info = [url resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey] error:NULL];
        if (![info[NSURLIsRegularFileKey] boolValue] || [info[NSURLIsSymbolicLinkKey] boolValue] ||
            [info[NSURLFileSizeKey] unsignedLongLongValue] > (1ULL << 30)) {
            [self showNotice:@"请选择小于或等于 1 GB 的普通文件"];
            return;
        }
        NSURLComponents *route = [[NSURLComponents alloc] init];
        route.path = @"/api/macos/native-upload";
        route.queryItems = @[[NSURLQueryItem queryItemWithName:@"name" value:url.lastPathComponent]];
        [self runAgent:@[@"agent", @"request", @"POST", route.string, @"--content-type", @"application/octet-stream", @"--input", url.path]
                  input:nil done:^(NSDictionary *value, NSString *failure) {
            if (!failure) [self showNotice:@"已上传到客机 下载 / VMac Uploads"];
        }];
    }];
}
- (IBAction)clipboardToGuest:(id)sender {
    if (self.busy) return;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if ([board canReadObjectForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}]) {
        [self showNotice:@"剪贴板里的文件请通过「上传文件」传输"];
        return;
    }
    NSString *text = [board stringForType:NSPasteboardTypeString];
    NSData *png = [board dataForType:NSPasteboardTypePNG];
    if (!png) {
        NSData *tiff = [board dataForType:NSPasteboardTypeTIFF];
        if (tiff.length <= (24 << 20) && tiff.length) {
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:tiff];
            if (bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 &&
                (double)bitmap.pixelsWide * bitmap.pixelsHigh <= 16000000) {
                png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            }
        }
    }
    NSDictionary *value;
    if (png.length && png.length <= (9 << 20)) value = @{@"operation":@"write", @"png":[png base64EncodedStringWithOptions:0]};
    else if (text && [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= (2 << 20)) value = @{@"operation":@"write", @"text":text};
    if (!value) { [self showNotice:@"请选择剪贴板中的文字或图片"]; return; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    [self runAgent:@[@"agent", @"request", @"POST", @"/api/macos/native-clipboard", @"--input", @"-"] input:data
            done:^(NSDictionary *result, NSString *failure) {
        if (!failure) [self showNotice:@"已传到客机剪贴板"];
    }];
}
- (IBAction)clipboardFromGuest:(id)sender {
    if (self.busy) return;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSInteger revision = board.changeCount;
    NSData *data = [@"{\"operation\":\"read\"}" dataUsingEncoding:NSUTF8StringEncoding];
    [self runAgent:@[@"agent", @"request", @"POST", @"/api/macos/native-clipboard", @"--input", @"-"] input:data
            done:^(NSDictionary *result, NSString *failure) {
        if (failure) return;
        if (!self.window.isKeyWindow || board.changeCount != revision) {
            [self showNotice:@"本机剪贴板已变化，请重试"];
            return;
        }
        NSDictionary *contents = result[@"body"];
        NSString *text = contents[@"text"];
        NSData *png = [[NSData alloc] initWithBase64EncodedString:contents[@"png"] ?: @"" options:0];
        if (![text isKindOfClass:NSString.class] && !png.length) return;
        [board clearContents];
        if (png.length) [board setData:png forType:NSPasteboardTypePNG];
        else [board setString:text forType:NSPasteboardTypeString];
        [self showNotice:@"已接收客机剪贴板"];
    }];
}
@end

static CageNativeVMWindow *nativeWindow;

