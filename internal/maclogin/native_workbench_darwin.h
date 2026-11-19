// The AppKit window belongs to the process that owns VZVirtualMachine.
#import "native_clipboard_darwin.h"

@interface CageNativeVMWindow : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) NSView *pane;
@property(nonatomic, strong) VZVirtualMachineView *view;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL shuttingDown;
@property(nonatomic, strong) CageDesktopClipboard *clipboard;
- (void)bringForward;
- (BOOL)acceptDrop:(id<NSDraggingInfo>)sender perform:(BOOL)perform;
@end

@interface CageDropVMView : VZVirtualMachineView
@property(nonatomic, weak) CageNativeVMWindow *owner;
@end

@implementation CageDropVMView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    return self;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [self.owner acceptDrop:sender perform:NO] ? NSDragOperationCopy : NSDragOperationNone;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self draggingEntered:sender];
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    return [self.owner acceptDrop:sender perform:YES];
}
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
    if (!self.clipboard) self.clipboard = [[CageDesktopClipboard alloc] init];
    [self.clipboard setDesktopVisible:YES];
}
- (void)showControls:(NSString *)reason {
    cageHideEmbeddedDesktop();
    if (showEmbeddedControls) showEmbeddedControls(reason.UTF8String);
}
- (IBAction)openControls:(id)sender {
    [self showControls:@"settings"];
}

- (void)runAgent:(NSArray<NSString *> *)args input:(NSData *)input file:(NSFileHandle *)file
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
        task.standardInput = pipe ?: file ?: NSFileHandle.fileHandleWithNullDevice;
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
        [file closeFile];
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
- (void)runAgent:(NSArray<NSString *> *)args input:(NSData *)input
            done:(void (^)(NSDictionary *, NSString *))done {
    [self runAgent:args input:input file:nil done:done];
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
        [self uploadURLs:panel.URLs];
    }];
}
- (void)uploadHandles:(NSArray<NSFileHandle *> *)handles names:(NSArray<NSString *> *)names
                batch:(NSString *)batch index:(NSUInteger)index {
    NSURLComponents *route = [[NSURLComponents alloc] init];
    route.path = @"/api/macos/native-upload";
    route.queryItems = @[[NSURLQueryItem queryItemWithName:@"name" value:names[index]],
                         [NSURLQueryItem queryItemWithName:@"batch" value:batch]];
    [self runAgent:@[@"agent", @"request", @"POST", route.string, @"--content-type", @"application/octet-stream", @"--input", @"-"]
              input:nil file:handles[index] done:^(NSDictionary *value, NSString *failure) {
        if (failure) {
            if (index) [self showNotice:[NSString stringWithFormat:@"已传输 %lu 个文件，后续停止：%@", (unsigned long)index, failure]];
        } else if (index + 1 < handles.count) {
            [self uploadHandles:handles names:names batch:batch index:index + 1];
        } else {
            [self showNotice:[NSString stringWithFormat:@"已传 %lu 个文件到客机「下载 / VMac Uploads / %@」", (unsigned long)handles.count, batch]];
            // Show the dropped files in the guest so they can be moved on from there.
            NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"batch":batch} options:0 error:NULL];
            [self runAgent:@[@"agent", @"request", @"POST", @"/api/macos/native-reveal", @"--input", @"-"] input:body
                    done:^(NSDictionary *result, NSString *problem) {}];
        }
    }];
}
- (BOOL)uploadURLs:(NSArray<NSURL *> *)urls {
    if (self.busy || urls.count == 0) return NO;
    if (urls.count > 20) { [self showNotice:@"一次最多拖入 20 个文件；更多文件请在 Mac 上复制（⌘C）后到客机粘贴（⌘V）"]; return NO; }
    NSMutableArray<NSFileHandle *> *handles = [NSMutableArray arrayWithCapacity:urls.count];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        if (!url.isFileURL || (url.host.length && ![url.host isEqualToString:@"localhost"])) return NO;
        int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        struct stat status;
        if (fd < 0 || fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size > (1LL << 30)) {
            BOOL folder = fd >= 0 && S_ISDIR(status.st_mode);
            if (fd >= 0) close(fd);
            [self showNotice:folder ? @"文件夹请在 Mac 上复制（⌘C），再到客机里粘贴（⌘V）"
                                    : @"拖入的文件需小于或等于 1 GB；更大的文件请压缩后再传"];
            return NO;
        }
        [handles addObject:[[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES]];
        [names addObject:url.lastPathComponent];
    }
    NSDateFormatter *format = [[NSDateFormatter alloc] init];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *batch = [NSString stringWithFormat:@"%@-%04x", [format stringFromDate:NSDate.date], arc4random_uniform(0x10000)];
    [self uploadHandles:handles names:names batch:batch index:0];
    return YES;
}
- (BOOL)acceptDrop:(id<NSDraggingInfo>)sender perform:(BOOL)perform {
    if (self.busy || self.pane.hidden || !self.view.virtualMachine || self.window.attachedSheet ||
        !(sender.draggingSourceOperationMask & NSDragOperationCopy)) return NO;
    NSPasteboard *board = sender.draggingPasteboard;
    NSDictionary *options = @{NSPasteboardURLReadingFileURLsOnlyKey:@YES};
    if (!perform) return [board canReadObjectForClasses:@[NSURL.class] options:options];
    NSArray<NSURL *> *urls = [board readObjectsForClasses:@[NSURL.class] options:options];
    return [self uploadURLs:urls];
}
- (IBAction)clipboardToGuest:(id)sender {
    if (self.busy) return;
    NSMutableDictionary *value = [transferableClipboard(NSPasteboard.generalPasteboard, NO) mutableCopy];
    if (!value) { [self showNotice:@"请选择剪贴板中的文字或图片"]; return; }
    value[@"operation"] = @"write";
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

