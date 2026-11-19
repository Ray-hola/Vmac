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
- (void)showNotice:(NSString *)message;
- (BOOL)acceptDrop:(id<NSDraggingInfo>)sender perform:(BOOL)perform;
@end

@interface CageDropVMView : VZVirtualMachineView <NSTextInputClient>
@property(nonatomic, weak) CageNativeVMWindow *owner;
@end

static BOOL plainASCII(NSString *text) {
    if (text.length != 1) return NO;
    unichar c = [text characterAtIndex:0];
    return c >= 0x20 && c < 0x7f;
}

// With the Mac's input method selected, keys are composed on the Mac and the
// committed text is pasted into the guest; everything else stays a raw key.
@implementation CageDropVMView {
    NSEvent *_keyEvent;
    NSString *_marked;
    NSTextField *_compose;
    NSMutableSet<NSNumber *> *_heldKeys;
    NSMutableArray<NSEvent *> *_deferred;
    NSUInteger _typing;
    NSTextInputContext *_textInput;
    NSPoint _caret;
    BOOL _caretKnown;
}
// The guest's caret is invisible to the Mac; the last click in the guest is
// the best estimate of where text goes, so the composition follows it.
- (void)mouseDown:(NSEvent *)event {
    _caret = [self convertPoint:event.locationInWindow fromView:nil];
    _caretKnown = YES;
    [super mouseDown:event];
}
- (NSRect)compositionFrame:(NSSize)size {
    NSPoint anchor = _caretKnown ? _caret : NSMakePoint(24, 24 + size.height + 8);
    NSRect frame = NSMakeRect(anchor.x, anchor.y - size.height - 8, size.width, size.height);
    frame.origin.x = MAX(8, MIN(NSMaxX(self.bounds) - size.width - 8, NSMinX(frame)));
    // Show it above the click when there is no room below.
    if (NSMinY(frame) < 8) frame.origin.y = MIN(NSMaxY(self.bounds) - size.height - 8, anchor.y + 16);
    return frame;
}
// The guest view has no text of its own; supply a context for the Mac's
// input method even if the framework view does not create one.
- (NSTextInputContext *)inputContext {
    if (!_textInput) _textInput = [[NSTextInputContext alloc] initWithClient:self];
    return _textInput;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        _heldKeys = [NSMutableSet set];
        _deferred = [NSMutableArray array];
    }
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
- (BOOL)routesThroughHostInputMethod:(NSEvent *)event {
    if (_marked.length) return YES;
    if (!hostInputMethodEnabled() || !self.owner.clipboard.canTypeText) return NO;
    if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return NO;
    NSString *source = self.inputContext.selectedKeyboardInputSource;
    return source.length && ![source hasPrefix:@"com.apple.keylayout."];
}
- (void)forwardKeyDown:(NSEvent *)event {
    [_heldKeys addObject:@(event.keyCode)];
    [super keyDown:event];
}
- (BOOL)deferEvent:(NSEvent *)event {
    if (!_typing && !_deferred.count) return NO;
    if (_deferred.count < 256) [_deferred addObject:event];
    return YES;
}
- (void)flushDeferred {
    while (_deferred.count && !_typing) {
        NSEvent *event = _deferred.firstObject;
        [_deferred removeObjectAtIndex:0];
        if (event.type == NSEventTypeKeyDown) [self handleKeyDown:event];
        else if (event.type == NSEventTypeKeyUp) [self handleKeyUp:event];
        else [super flagsChanged:event];
    }
}
- (void)keyDown:(NSEvent *)event {
    if (![self deferEvent:event]) [self handleKeyDown:event];
}
- (void)handleKeyDown:(NSEvent *)event {
    if (![self routesThroughHostInputMethod:event]) { [self forwardKeyDown:event]; return; }
    _keyEvent = event;
    BOOL handled = [self.inputContext handleEvent:event];
    // Keys the input method did not use still belong to the guest.
    if (!handled && _keyEvent == event) [self forwardKeyDown:event];
    _keyEvent = nil;
}
- (void)keyUp:(NSEvent *)event {
    if (![self deferEvent:event]) [self handleKeyUp:event];
}
- (void)handleKeyUp:(NSEvent *)event {
    // Only release keys whose press reached the guest.
    if (![_heldKeys containsObject:@(event.keyCode)]) return;
    [_heldKeys removeObject:@(event.keyCode)];
    [super keyUp:event];
}
- (void)flagsChanged:(NSEvent *)event {
    if (![self deferEvent:event]) [super flagsChanged:event];
}
- (void)showComposition:(NSString *)text {
    if (!text.length) { _compose.hidden = YES; return; }
    if (!_compose) {
        _compose = [NSTextField labelWithString:@""];
        _compose.font = [NSFont systemFontOfSize:15];
        _compose.textColor = NSColor.whiteColor;
        _compose.wantsLayer = YES;
        _compose.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:0.82].CGColor;
        _compose.layer.cornerRadius = 7;
        _compose.alignment = NSTextAlignmentCenter;
        [self addSubview:_compose];
    }
    _compose.stringValue = text;
    NSSize size = _compose.intrinsicContentSize;
    _compose.frame = [self compositionFrame:NSMakeSize(MIN(size.width + 20, NSWidth(self.bounds) - 16), size.height + 8)];
    _compose.hidden = NO;
}
- (void)clearComposition {
    _marked = nil;
    _compose.hidden = YES;
}
- (void)pasteText:(NSString *)text {
    CageDesktopClipboard *clipboard = self.owner.clipboard;
    _typing++;
    __weak typeof(self) weakSelf = self;
    [clipboard typeText:text ready:^(BOOL ok) {
        CageDropVMView *view = weakSelf;
        if (!view) return;
        if (ok) [view sendPasteShortcut];
        else [view.owner showNotice:@"Mac 输入法的文字没能送进客机，请重试或改用客机输入法"];
        view->_typing--;
        [view flushDeferred];
    }];
}
- (void)sendPasteShortcut {
    NSInteger window = self.window.windowNumber;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSEvent *(^key)(NSEventType, NSEventModifierFlags, unsigned short, NSString *) =
        ^(NSEventType type, NSEventModifierFlags flags, unsigned short code, NSString *characters) {
            return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:now windowNumber:window
                                     context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:code];
        };
    // The guest view decides whether a modifier went down from the
    // device-dependent bit of that key (NX_DEVICELCMDKEYMASK for the left
    // Command key), not from the device-independent Command flag alone.
    const NSEventModifierFlags idle = 0x100, command = NSEventModifierFlagCommand | 0x100 | 0x8;
    [super flagsChanged:key(NSEventTypeFlagsChanged, command, 55, @"")];
    [super keyDown:key(NSEventTypeKeyDown, command, 9, @"v")];
    [super keyUp:key(NSEventTypeKeyUp, command, 9, @"v")];
    [super flagsChanged:key(NSEventTypeFlagsChanged, idle, 55, @"")];
}

#pragma mark NSTextInputClient
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    BOOL composing = _marked.length > 0;
    [self clearComposition];
    NSEvent *event = _keyEvent;
    _keyEvent = nil;
    // A plain character straight from a key press is sent as that key, so the
    // guest's own layout, shortcuts and key repeat keep working.
    if (!composing && event && plainASCII(text) && [text isEqualToString:event.characters]) { [self forwardKeyDown:event]; return; }
    if (text.length) [self pasteText:text];
}
- (void)doCommandBySelector:(SEL)selector {
    NSEvent *event = _keyEvent;
    _keyEvent = nil;
    if (event) [self forwardKeyDown:event];
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    _keyEvent = nil;
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    _marked = text.length ? [text copy] : nil;
    [self showComposition:text];
}
- (void)unmarkText { [self clearComposition]; }
- (BOOL)hasMarkedText { return _marked.length > 0; }
- (NSRange)markedRange { return _marked.length ? NSMakeRange(0, _marked.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(_marked.length, 0); }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange { return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    // The guest caret is not visible to the Mac; candidates follow the overlay.
    NSRect local = _compose && !_compose.hidden ? _compose.frame : [self compositionFrame:NSMakeSize(1, 22)];
    return self.window ? [self.window convertRectToScreen:[self convertRect:local toView:nil]] : NSZeroRect;
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
                batch:(NSString *)batch folder:(NSString *)folder label:(NSString *)label index:(NSUInteger)index {
    NSURLComponents *route = [[NSURLComponents alloc] init];
    route.path = @"/api/macos/native-upload";
    route.queryItems = @[[NSURLQueryItem queryItemWithName:@"name" value:names[index]],
                         folder ? [NSURLQueryItem queryItemWithName:@"target" value:folder]
                                : [NSURLQueryItem queryItemWithName:@"batch" value:batch]];
    [self runAgent:@[@"agent", @"request", @"POST", route.string, @"--content-type", @"application/octet-stream", @"--input", @"-"]
              input:nil file:handles[index] done:^(NSDictionary *value, NSString *failure) {
        if (failure) {
            if (index) [self showNotice:[NSString stringWithFormat:@"已传输 %lu 个文件，后续停止：%@", (unsigned long)index, failure]];
        } else if (index + 1 < handles.count) {
            [self uploadHandles:handles names:names batch:batch folder:folder label:label index:index + 1];
        } else if (folder) {
            [self showNotice:[NSString stringWithFormat:@"已把 %lu 个文件放到客机「%@」", (unsigned long)handles.count, label]];
        } else {
            [self showNotice:[NSString stringWithFormat:@"已传 %lu 个文件到客机「下载 / VMac Uploads / %@」", (unsigned long)handles.count, batch]];
            // Show the uploaded files in the guest so they can be moved on from there.
            NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"batch":batch} options:0 error:NULL];
            [self runAgent:@[@"agent", @"request", @"POST", @"/api/macos/native-reveal", @"--input", @"-"] input:body
                    done:^(NSDictionary *result, NSString *problem) {}];
        }
    }];
}
// Opens every file first, so a bad selection is refused before anything is sent.
- (BOOL)openUploads:(NSArray<NSURL *> *)urls handles:(NSMutableArray<NSFileHandle *> *)handles names:(NSMutableArray<NSString *> *)names {
    if (self.busy || urls.count == 0) return NO;
    if (urls.count > 50) { [self showNotice:@"一次最多拖入 50 个文件；更多文件请在 Mac 上复制（⌘C）后到客机粘贴（⌘V）"]; return NO; }
    for (NSURL *url in urls) {
        if (!url.isFileURL || (url.host.length && ![url.host isEqualToString:@"localhost"])) return NO;
        int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        struct stat status;
        if (fd < 0 || fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size > (8LL << 30)) {
            BOOL folder = fd >= 0 && S_ISDIR(status.st_mode);
            if (fd >= 0) close(fd);
            [self showNotice:folder ? @"文件夹请在 Mac 上复制（⌘C），再到客机里粘贴（⌘V）"
                                    : @"拖入的文件需小于或等于 8 GB；更大的文件请压缩或分卷后再传"];
            return NO;
        }
        [handles addObject:[[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES]];
        [names addObject:url.lastPathComponent];
    }
    return YES;
}
- (BOOL)uploadURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSFileHandle *> *handles = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (![self openUploads:urls handles:handles names:names]) return NO;
    NSDateFormatter *format = [[NSDateFormatter alloc] init];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *batch = [NSString stringWithFormat:@"%@-%04x", [format stringFromDate:NSDate.date], arc4random_uniform(0x10000)];
    [self uploadHandles:handles names:names batch:batch folder:nil label:nil index:0];
    return YES;
}
// A drop lands where it was released: the guest names the Finder window or
// the Desktop under that point, then each file is written straight there.
- (BOOL)dropURLs:(NSArray<NSURL *> *)urls at:(NSPoint)location {
    NSMutableArray<NSFileHandle *> *handles = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (![self openUploads:urls handles:handles names:names]) return NO;
    NSRect bounds = self.view.bounds;
    double x = NSWidth(bounds) > 0 ? MIN(1, MAX(0, (location.x - NSMinX(bounds)) / NSWidth(bounds))) : 0.5;
    double y = NSHeight(bounds) > 0 ? MIN(1, MAX(0, 1 - (location.y - NSMinY(bounds)) / NSHeight(bounds))) : 0.5;
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"x":@(x), @"y":@(y)} options:0 error:NULL];
    [self runAgent:@[@"agent", @"request", @"POST", @"/api/macos/native-drop", @"--input", @"-"] input:body
            done:^(NSDictionary *value, NSString *failure) {
        NSDictionary *target = [value[@"body"] isKindOfClass:NSDictionary.class] ? value[@"body"] : nil;
        NSString *folder = [target[@"folder"] isKindOfClass:NSString.class] ? target[@"folder"] : nil;
        NSString *label = [target[@"label"] isKindOfClass:NSString.class] ? target[@"label"] : folder.lastPathComponent;
        if (!folder.length) {
            // An older backend cannot resolve the drop point; keep the upload folder.
            NSDateFormatter *format = [[NSDateFormatter alloc] init];
            format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            format.dateFormat = @"yyyyMMdd-HHmmss";
            NSString *batch = [NSString stringWithFormat:@"%@-%04x", [format stringFromDate:NSDate.date], arc4random_uniform(0x10000)];
            [self uploadHandles:handles names:names batch:batch folder:nil label:nil index:0];
            return;
        }
        [self uploadHandles:handles names:names batch:nil folder:folder label:label index:0];
    }];
    return YES;
}
- (BOOL)acceptDrop:(id<NSDraggingInfo>)sender perform:(BOOL)perform {
    if (self.busy || self.pane.hidden || !self.view.virtualMachine || self.window.attachedSheet ||
        !(sender.draggingSourceOperationMask & NSDragOperationCopy)) return NO;
    NSPasteboard *board = sender.draggingPasteboard;
    NSDictionary *options = @{NSPasteboardURLReadingFileURLsOnlyKey:@YES};
    if (!perform) return [board canReadObjectForClasses:@[NSURL.class] options:options];
    NSArray<NSURL *> *urls = [board readObjectsForClasses:@[NSURL.class] options:options];
    return [self dropURLs:urls at:[self.view convertPoint:sender.draggingLocation fromView:nil]];
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

