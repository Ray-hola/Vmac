import Cocoa
import WebKit
import UniformTypeIdentifiers

#if CAGE_EMBEDDED_VM
@_silgen_name("cageStartEmbeddedVMHost")
private func startEmbeddedVMHost(_ config: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("cageRegisterEmbeddedWindow")
private func registerEmbeddedWindow(_ window: UnsafeMutableRawPointer, _ mount: UnsafeMutableRawPointer, _ control: @convention(c) (UnsafePointer<CChar>) -> Void)

@_silgen_name("cageHideEmbeddedDesktop")
private func hideEmbeddedDesktop()

@_silgen_name("cageEmbeddedUtility")
private func performEmbeddedUtility(_ action: UnsafePointer<CChar>) -> Bool

private func showEmbeddedControls(_ reason: UnsafePointer<CChar>) {
    CageApp.embeddedOwner?.embeddedControlsRequested(String(cString: reason))
}
#endif


enum CageDiagnostics {
    static func record(_ message: String) {
        guard let executable = Bundle.main.url(forResource: CageProfile.backendName, withExtension: nil),
              let data = try? JSONSerialization.data(withJSONObject: ["source":"native", "message":String(message.prefix(4096))]) else { return }
        let process = Process(); process.executableURL = executable; process.arguments = ["diagnostic-event"]
        let input = Pipe(); process.standardInput = input
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); try input.fileHandleForWriting.write(contentsOf: data); try input.fileHandleForWriting.close() } catch { }
    }
}

@main
final class CageApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var nativeInput: CageNativeInput!
    private var guestSidebar: CageGuestSidebar?
    private var guestContent: NSView!
    private var guestSplitView: NSSplitView?
    private var vmacToolbar: VMacToolbarController?
    private var toast: VMacToastView?
    private var preferredSidebarWidth: CGFloat = 220
    private var shell = VMacShellState()
    private var shellMenuItems: [VMacMenuKey: NSMenuItem] = [:]
    private var accountDeviceBusy = false
    private var expectedPort = 0
    private var allowQuit = false
    private var nativeFilePanelOpen = false
    private var guestDesktopVisible = false
    private var embeddedEnvironment: [String: String] = [:]
    #if CAGE_EMBEDDED_VM
    fileprivate static weak var embeddedOwner: CageApp?
    #endif
    private var fileSelections: [String: (paths: [String], expires: Date)] = [:]
    private var clipboardGeneration = 0
    private var clipboardCopies: [String: [String]] = [:]
    private var clipboardReaders: [UUID: [String]] = [:]
    private var clipboardPending = Set<String>()
    private var clipboardReleasing = Set<String>()
    private var clipboardCacheLoaded = false
    private var clipboardCacheTimer: Timer?
    private var loading: NSTextField!
    private var retry: NSButton!
    private var backdrop: NSVisualEffectView!
    private var completeUpdateButton: NSButton!
    private var existingEnvironmentButton: NSButton!
    private var completeUpdateMenu: NSMenuItem!
    private var controllerNeedsUpdate = false
    private var appUpdater: CageAppUpdater!
    private var nativeVMTest: Bool {
        nativeVMWorkbench || Bundle.main.object(forInfoDictionaryKey: "CageNativeVMTest") as? Bool == true
    }
    private var nativeVMWorkbench: Bool { CageProfile.isVMac }
    private var workbenchTitle: String {
        if nativeVMWorkbench { return "VMac" }
        if nativeVMTest { return "VMac 原生 VM 测试版" }
        return CageProfile.macGuestTrial ? "VMac macOS" : "VMac"
    }

    private struct DesktopEntry {
        let status: String
        let url: URL?
        let message: String
    }

    static func main() {
        CageProfile.migrateVMacPreferences()
        CageProfile.pinEnvironment()
        if CommandLine.arguments.dropFirst().elementsEqual(["--store-trial-guest-password"]) {
            do { try MacGuestLoginCredential.importFromPipe(); return }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        NSSetUncaughtExceptionHandler { exception in CageDiagnostics.record("Uncaught native exception: \(exception.name.rawValue): \(exception.reason ?? "")\n\(exception.callStackSymbols.joined(separator: "\n"))") }
        let app = NSApplication.shared
        let delegate = CageApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path=Bundle.main.path(forResource:"VMac",ofType:"icns"),let icon=NSImage(contentsOfFile:path) { NSApp.applicationIconImage=icon }
        let appearance = UserDefaults.standard.dictionary(forKey: nativeVMWorkbench ? "vmac.windowAppearance" : "cage.windowAppearance") ?? [:]
        let mode = appearance["mode"] as? String ?? "system"
        NSApp.appearance = nativeVMWorkbench ? vmacAppearance : mode == "system" ? nil : NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        makeMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = workbenchTitle
        window.titlebarAppearsTransparent = false
        window.backgroundColor = nativeVMWorkbench ? CagePalette.paper : NSColor(srgbRed: 247.0/255, green: 247.0/255, blue: 247.0/255, alpha: 1)
        if nativeVMWorkbench { window.collectionBehavior.insert(.fullScreenPrimary) }
        window.minSize = NSSize(width: 820, height: 580)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if nativeVMWorkbench { installVMacToolbar() }
        window.setFrameAutosaveName("CageMainWindow")
        window.center()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "cage")
        config.userContentController.addUserScript(WKUserScript(source: "window.cageNativeIMEAvailable = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if nativeVMWorkbench {
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let encodedBuild = String(data: (try? JSONSerialization.data(withJSONObject: [build])) ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
            let source = "window.cageNativeVMWorkbench = true; window.vmacVMOnlySetup = \(CageProfile.activeProfile != CageProfile.defaultProfile); window.vmacBuild = \(encodedBuild)[0];"
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        let root = window.contentView!
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = nativeVMWorkbench
        guestContent = content
        if nativeVMWorkbench {
            let savedWidth = UserDefaults.standard.object(forKey: "vmac.sidebarWidth.v2") as? Double ?? 220
            preferredSidebarWidth = CGFloat(min(280, max(180, savedWidth)))
            let sidebar = CageGuestSidebar()
            sidebar.onSelect = { [weak self] destination in self?.selectGuestDestination(destination) }
            let split = NSSplitView(frame: root.bounds)
            split.isVertical = true
            split.dividerStyle = .thin
            sidebar.translatesAutoresizingMaskIntoConstraints = true
            content.translatesAutoresizingMaskIntoConstraints = true
            sidebar.frame = NSRect(x: 0, y: 0, width: preferredSidebarWidth, height: root.bounds.height)
            content.frame = NSRect(x: preferredSidebarWidth + 1, y: 0, width: max(0, root.bounds.width - preferredSidebarWidth - 1), height: root.bounds.height)
            split.addSubview(sidebar)
            split.addSubview(content)
            root.addSubview(split)
            guestSidebar = sidebar
            guestSplitView = split
            split.delegate = self
            split.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                split.topAnchor.constraint(equalTo: root.topAnchor),
                split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            split.setPosition(preferredSidebarWidth, ofDividerAt: 0)
            // Floats over the bottom of the content, above the page and the guest view alike.
            let toast = VMacToastView()
            toast.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(toast)
            NSLayoutConstraint.activate([
                toast.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
                toast.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32),
            ])
            self.toast = toast
            window.minSize = NSSize(width: 1000, height: 640)
        } else {
            root.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                content.topAnchor.constraint(equalTo: root.topAnchor),
                content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        backdrop = NSVisualEffectView(frame: content.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        content.addSubview(backdrop)
        content.addSubview(webView)
        nativeInput = CageNativeInput(frame: .zero)
        nativeInput.configure(web: webView)
        content.addSubview(nativeInput)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: content.leadingAnchor), webView.trailingAnchor.constraint(equalTo: content.trailingAnchor), webView.topAnchor.constraint(equalTo: content.topAnchor), webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        loading = NSTextField(labelWithString: "正在启动 VMac 工作台…")
        loading.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        loading.textColor = NSColor(srgbRed: 54.0/255, green: 54.0/255, blue: 54.0/255, alpha: 1)
        loading.alignment = .center
        loading.maximumNumberOfLines = 4
        loading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(loading)
        retry = NSButton(title: "重试连接", target: self, action: #selector(retryConnection))
        retry.bezelStyle = .rounded
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.isHidden = true
        content.addSubview(retry)
        completeUpdateButton = NSButton(title: "保存后停止环境并完成更新", target: self, action: #selector(completePendingUpdate))
        completeUpdateButton.bezelStyle = .rounded
        completeUpdateButton.translatesAutoresizingMaskIntoConstraints = false
        completeUpdateButton.isHidden = true
        content.addSubview(completeUpdateButton)
        existingEnvironmentButton = NSButton(title: "打开现有环境保存文件", target: self, action: #selector(openExistingEnvironment))
        existingEnvironmentButton.bezelStyle = .rounded
        existingEnvironmentButton.translatesAutoresizingMaskIntoConstraints = false
        existingEnvironmentButton.isHidden = true
        content.addSubview(existingEnvironmentButton)
        NSLayoutConstraint.activate([loading.centerXAnchor.constraint(equalTo: content.centerXAnchor), loading.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -16), loading.widthAnchor.constraint(lessThanOrEqualToConstant: 600), retry.centerXAnchor.constraint(equalTo: content.centerXAnchor), retry.topAnchor.constraint(equalTo: loading.bottomAnchor, constant: 20)])
        NSLayoutConstraint.activate([existingEnvironmentButton.centerXAnchor.constraint(equalTo: content.centerXAnchor), existingEnvironmentButton.topAnchor.constraint(equalTo: retry.bottomAnchor, constant: 10), completeUpdateButton.centerXAnchor.constraint(equalTo: content.centerXAnchor), completeUpdateButton.topAnchor.constraint(equalTo: existingEnvironmentButton.bottomAnchor, constant: 10)])
        applyAppearance(appearance)
        #if CAGE_EMBEDDED_VM
        if nativeVMWorkbench {
            let result = CageProfile.configURL().path.withCString { startEmbeddedVMHost($0) }
            guard let result else { window.makeKeyAndOrderFront(nil); showError("无法初始化原生客机运行器"); return }
            defer { free(result) }
            guard let env = try? JSONSerialization.jsonObject(with: Data(String(cString: result).utf8)) as? [String: String],
                  env["CAGE_EMBEDDED_VM_SOCKET"] != nil, env["CAGE_EMBEDDED_VM_TOKEN"] != nil else {
                window.makeKeyAndOrderFront(nil)
                showError("无法初始化原生客机运行器")
                return
            }
            embeddedEnvironment = env
            Self.embeddedOwner = self
            registerEmbeddedWindow(Unmanaged.passUnretained(window).toOpaque(), Unmanaged.passUnretained(guestContent).toOpaque(), showEmbeddedControls)
        }
        #endif
        appUpdater = CageAppUpdater(bundleURL: Bundle.main.bundleURL, onChange: { [weak self] state in
            if state["phase"] as? String == "failed" { CageDiagnostics.record("App update failed: " + (state["message"] as? String ?? "unknown error")) }
            guard let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
            self?.webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('cage-app-update',{detail:\(json)}));", completionHandler: nil)
        }, quit: { [weak self] in self?.allowQuit = true; NSApp.terminate(nil) }, reconnect: { [weak self] in self?.bootstrap() })
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        bootstrap()
    }
    private func makeMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "VMac")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 VMac", action: #selector(about), keyEquivalent: "")
        if !nativeVMTest || Bundle.main.bundleIdentifier == CageProfile.vmacBundleID {
            appMenu.addItem(withTitle: "检查应用更新…", action: #selector(checkApplicationUpdate), keyEquivalent: "")
        }
        completeUpdateMenu = appMenu.addItem(withTitle: "完成待安装更新…", action: #selector(completePendingUpdate), keyEquivalent: "")
        completeUpdateMenu.isHidden = true
        appMenu.addItem(.separator())
        if CageProfile.macGuestTrial {
            appMenu.addItem(withTitle: "复制试用客机登录密码", action: #selector(copyGuestLoginPassword), keyEquivalent: "")
        }
        if nativeVMWorkbench && CageProfile.activeProfile != CageProfile.defaultProfile {
            appMenu.addItem(withTitle: "返回原有 macOS 客机", action: #selector(returnFromNewProfile), keyEquivalent: "")
        }
        shellMenuItems[.settings] = appMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        shellMenuItems[.hide] = appMenu.addItem(withTitle: "隐藏 VMac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        shellMenuItems[.quit] = appMenu.addItem(withTitle: "退出 VMac…", action: #selector(requestQuit), keyEquivalent: "q")
        let file = NSMenu(title: "文件")
        // These belong to the shared workbench; VMac has no projects, tabs or terminals.
        if !nativeVMWorkbench {
            file.addItem(withTitle: "打开项目…", action: #selector(openProject), keyEquivalent: "o")
            file.addItem(.separator())
            file.addItem(withTitle: "新建网页", action: #selector(newTab), keyEquivalent: "t")
            let terminal = file.addItem(withTitle: "新建终端", action: #selector(newTerminal), keyEquivalent: "\r")
            terminal.keyEquivalentModifierMask = [.command, .shift]
            file.addItem(withTitle: "关闭当前标签", action: #selector(closeTab), keyEquivalent: "w")
            file.addItem(.separator())
        }
        file.addItem(withTitle: "关闭窗口（保留环境）", action: #selector(closeWindow), keyEquivalent: "")
        if nativeVMWorkbench {
            file.addItem(.separator())
            let clipboard = file.addItem(withTitle: "共享剪贴板（文字、图片和文件）", action: #selector(toggleGuestClipboard(_:)), keyEquivalent: "")
            clipboard.state = Self.vmacPreference("vmac.shareClipboardContent") ? .on : .off
            let input = file.addItem(withTitle: "用 Mac 输入法在客机中打字", action: #selector(toggleHostInputMethod(_:)), keyEquivalent: "")
            input.state = Self.vmacPreference("vmac.hostInputMethod") ? .on : .off
            for (title, action) in [
                ("上传文件到客机…", "upload"),
                ("传文字或图片到客机", "clipboard-to-guest"),
                ("接收客机文字或图片", "clipboard-from-guest")
            ] {
                let item = file.addItem(withTitle: title, action: #selector(guestUtility(_:)), keyEquivalent: "")
                item.representedObject = action
            }
        }
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        fileItem.submenu = file; main.addItem(fileItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: #selector(editUndo), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: #selector(editRedo), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(editCut), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(editCopy), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(editPaste), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(editSelectAll), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        let view = NSMenu(title: "窗口")
        let minimize = view.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        view.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = view.addItem(withTitle: "进入全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        if nativeVMWorkbench {
            view.addItem(.separator())
            shellMenuItems[.controlCenter] = view.addItem(withTitle: "控制中心", action: #selector(toggleControlCenter), keyEquivalent: "")
            shellMenuItems[.minimize] = minimize
            shellMenuItems[.fullScreen] = fullScreen
        } else {
            shellMenuItems.removeAll()
        }
        let viewItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); viewItem.submenu = view; main.addItem(viewItem)
        NSApp.mainMenu = main
        refreshMenuKeys()
    }
    @objc private func editUndo(){edit("undo",fallback:"undo:")}
    @objc private func editRedo(){edit("redo",fallback:"redo:")}
    @objc private func editCut(){edit("cut",fallback:"cut:")}
    @objc private func editCopy(){edit("copy",fallback:"copy:")}
    @objc private func editPaste(){edit("paste",fallback:"paste:")}
    @objc private func editSelectAll(){edit("selectAll",fallback:"selectAll:")}
    private func edit(_ command:String,fallback:String){
        if nativeFilePanelOpen || window.attachedSheet != nil {
            NSApp.sendAction(Selector(fallback), to: nil, from: self)
            return
        }
        webView.evaluateJavaScript("window.cageEditAction?.('\(command)') ?? false") {result,error in
            if (result as? Bool) != true {NSApp.sendAction(Selector(fallback),to:nil,from:self)}
        }
    }
    @objc private func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CageVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本"
        let status = controllerNeedsUpdate ? "\n当前连接旧后台；更新尚未完成。" : ""
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName:"VMac", .applicationVersion:version, .credits:NSAttributedString(string:"本机隔离编码工作区\n基于 agent-vm、Lima、Chromium、noVNC 与 xterm.js" + status)])
    }
    @objc private func copyGuestLoginPassword() {
        do { try MacGuestLoginCredential.copyForLogin() }
        catch { let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        shell.sidebarVisible ? 180 : 0
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        shell.sidebarVisible ? min(280, splitView.bounds.width - 600) : 0
    }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        !shell.sidebarVisible
    }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== guestSidebar
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView === guestSplitView, let sidebar = guestSidebar else { return }
        let frames = shellFrames(in: splitView)
        sidebar.frame = frames.sidebar
        guestContent.frame = frames.content
    }
    /// The sidebar keeps its width and slides off the left edge on the guest desktop.
    private func shellFrames(in split: NSSplitView) -> (sidebar: NSRect, content: NSRect) {
        let bounds = split.bounds, width = preferredSidebarWidth
        guard shell.sidebarVisible else {
            return (NSRect(x: -width - split.dividerThickness, y: 0, width: width, height: bounds.height), bounds)
        }
        return (NSRect(x: 0, y: 0, width: width, height: bounds.height),
                NSRect(x: width + split.dividerThickness, y: 0, width: max(0, bounds.width - width - split.dividerThickness), height: bounds.height))
    }
    /// Shows the window in its current shell mode: sidebar, toolbar switch and shortcuts.
    private func applyShell(animated: Bool) {
        guard nativeVMWorkbench else { return }
        vmacToolbar?.setControlCenterActive(shell.mode == .controlCenter)
        refreshMenuKeys()
        guard let split = guestSplitView, let sidebar = guestSidebar else { return }
        let frames = shellFrames(in: split)
        guard sidebar.frame != frames.sidebar || guestContent.frame != frames.content else { return }
        if shell.sidebarVisible { sidebar.isHidden = false }
        let finish = { [weak self] in
            guard let self, let split = self.guestSplitView else { return }
            sidebar.isHidden = !self.shell.sidebarVisible
            split.needsDisplay = true
        }
        guard animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            sidebar.frame = frames.sidebar; guestContent.frame = frames.content; finish(); return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            sidebar.animator().frame = frames.sidebar
            self.guestContent.animator().frame = frames.content
        }, completionHandler: finish)
    }
    private func refreshMenuKeys() {
        for (key, item) in shellMenuItems {
            let equivalent = VMacMenuKeys.equivalent(for: key, mode: shell.mode)
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
    }
    private var vmacAppearance: NSAppearance? {
        vmacAppearanceName(for: UserDefaults.standard.string(forKey: "vmac.appearance")).flatMap { NSAppearance(named: $0) }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? NSSplitView, split === guestSplitView,
              NSApp.currentEvent?.type == .leftMouseDragged,
              shell.sidebarVisible, let width = guestSidebar?.frame.width, width >= 180, width <= 280 else { return }
        preferredSidebarWidth = width
        UserDefaults.standard.set(Double(width), forKey: "vmac.sidebarWidth.v2")
    }

    private func relaunchVMac(profile id: String, reply: @escaping (Any?, String?) -> Void) {
        let options = NSWorkspace.OpenConfiguration()
        options.createsNewApplicationInstance = true
        options.arguments = ["--vmac-profile", id]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: options) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { reply(nil, error.localizedDescription); return }
                UserDefaults.standard.set(id, forKey: "vmac.activeGuest")
                reply(true, nil)
                self.allowQuit = true
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func returnFromNewProfile() {
        let folder = CageProfile.profileFolder(CageProfile.activeProfile)
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("macos-guest.json").path),
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent("state/lima/mac/disk").path) else {
            toast?.show("请在虚拟机管理中切换", kind: .info)
            return
        }
        relaunchVMac(profile: CageProfile.defaultProfile) { [weak self] _, error in
            if let error { self?.toast?.show(error, kind: .error) }
        }
    }

    @objc private func guestUtility(_ sender: NSMenuItem) {
        #if CAGE_EMBEDDED_VM
        guard let action = sender.representedObject as? String else { return }
        if !action.withCString({ performEmbeddedUtility($0) }) {
            toast?.show("请先打开客机桌面", kind: .info)
        }
        #endif
    }

    // Clipboard sharing and the Mac input method default to on.
    private static func vmacPreference(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
    }
    @objc private func toggleGuestClipboard(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "vmac.shareClipboardContent")
        publishWindowVisibility()
        toast?.show(enabled ? "客机桌面可见时，复制的文字、图片和文件会双向同步" : "剪贴板共享已关闭", kind: .info)
    }
    @objc private func toggleHostInputMethod(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "vmac.hostInputMethod")
        publishWindowVisibility()
        toast?.show(enabled ? "在客机里打字时使用 Mac 当前的输入法；客机请切换到英文（ABC）输入" : "已改用客机自己的输入法", kind: .info)
    }

    private func installVMacToolbar() {
        let toolbar = VMacToolbarController()
        toolbar.onToggleControlCenter = { [weak self] in self?.toggleControlCenter() }
        toolbar.onShowOverview = { [weak self] in self?.selectGuestDestination("lifecycle") }
        #if CAGE_EMBEDDED_VM
        toolbar.onUpload = { _ = "upload".withCString { performEmbeddedUtility($0) } }
        #endif
        toolbar.onFullScreen = { [weak self] in self?.window.toggleFullScreen(nil) }
        // Restart and stop are confirmed by the workbench page, like its own buttons.
        toolbar.onRestart = { [weak self] in self?.selectGuestDestination("restart") }
        toolbar.onStop = { [weak self] in self?.selectGuestDestination("stop") }
        toolbar.update(VMacStatus(name: activeProfileName(), tone: "idle", detail: "正在读取"))
        toolbar.install(in: window)
        vmacToolbar = toolbar
    }
    /// The toolbar switch: from the guest desktop to the control center and back.
    @objc private func toggleControlCenter() {
        switch shell.toggleAction() {
        case .showControlCenter: showGuestControls()
        case .showDesktop: guestSidebar?.select("desktop"); guestDesktopCommand { _, _ in }
        case .none: break
        }
    }
    private func selectGuestDestination(_ destination: String) {
        if destination == "settings" { settings(); return }
        showGuestControls()
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [destination]), encoding: .utf8)!
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('cage-guest-navigate', {detail: \(quoted)[0]}));", completionHandler: nil)
    }
    /// Cross-fades the content area when it switches between the workbench page and the guest desktop.
    private func fadeGuestContent() {
        guard nativeVMWorkbench, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = guestContent?.layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.32
        transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(transition, forKey: "vmac-content-fade")
    }
    private func showGuestControls() {
        if guestDesktopVisible || webView.isHidden { fadeGuestContent() }
        guestDesktopVisible = false
        shell.controlsRequested()
        applyShell(animated: true)
        #if CAGE_EMBEDDED_VM
        if nativeVMWorkbench { hideEmbeddedDesktop() }
        #endif
        webView.isHidden = false
        window.makeFirstResponder(webView)
        window.makeKeyAndOrderFront(nil)
        publishWindowVisibility()
    }
    fileprivate func embeddedControlsRequested(_ reason: String) {
        if reason.hasPrefix("notice:") {
            toast?.show(String(reason.dropFirst("notice:".count)), kind: .info)
            return
        }
        if reason.hasPrefix("error:") {
            toast?.show(String(reason.dropFirst("error:".count)), kind: .error)
            return
        }
        showGuestControls()
        if reason == "restarting" || reason == "stopped" {
            guestSidebar?.select("lifecycle")
        }
        CageDiagnostics.record("Embedded guest view returned to controls (\(reason)) in window \(window.windowNumber)")
        guard reason == "restarting" || reason == "settings" else { return }
        let signal = reason == "restarting" ? "cage-guest-restarting" : "cage-guest-settings"
        webView.evaluateJavaScript("window.dispatchEvent(new Event('\(signal)'));", completionHandler: nil)
    }
    @objc private func settings() {
        if nativeVMWorkbench {
            showGuestControls()
            webView.evaluateJavaScript("window.dispatchEvent(new Event('cage-guest-settings'));", completionHandler: nil)
        } else { action("settings") }
    }
    @objc private func openProject() { action("openProject") }
    @objc private func newTab() { action("newTab") }
    @objc private func newTerminal() { action("newTerminal") }
    @objc private func closeTab() { action("closeTab") }
    @objc private func closeWindow() { window.close() }
    @objc private func requestQuit() { NSApp.terminate(nil) }
    @objc private func checkApplicationUpdate() { _ = appUpdater?.handle("check") }
    @objc private func retryConnection() { bootstrap() }
    @objc private func openExistingEnvironment() { bootstrap(options: ["--existing"]) }
    @objc private func completePendingUpdate() {
        let alert = NSAlert()
        alert.messageText = "保存文件后完成更新"
        alert.informativeText = "这会停止现有环境和终端任务，再切换到新版后台。项目文件和登录状态会保留。请先保存编辑器中的修改。"
        alert.addButton(withTitle: "已保存，停止并更新")
        alert.addButton(withTitle: "继续当前工作")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { self.bootstrap(options: ["--complete-update"]) }
        }
    }
    private func action(_ name: String) { webView.evaluateJavaScript("window.cageNativeAction?.('\(name)')", completionHandler: nil) }
    private func requestEntry(options: [String] = [], _ completion: @escaping (Result<DesktopEntry, Error>) -> Void) {
        if CageProfile.macGuestTrial {
            let binding = CageProfile.configURL().deletingLastPathComponent().appendingPathComponent("macos-guest.json")
            guard FileManager.default.fileExists(atPath: binding.path) else {
                completion(.failure(CageUpdateError("这份试用版尚未绑定 macOS 客机，准备完成后请点重试。"))); return
            }
        }
        guard let executable = Bundle.main.url(forResource: CageProfile.backendName, withExtension: nil) else {
            completion(.failure(NSError(domain: "Cage", code: 1))); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); process.executableURL = executable; process.arguments = ["desktop", "--json"] + options
            var environment = ProcessInfo.processInfo.environment
            environment["CAGE_DESKTOP_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            environment.merge(self.embeddedEnvironment) { _, current in current }
            process.environment = environment
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let result = try JSONSerialization.jsonObject(with: data) as? [String:Any]
                let message = result?["message"] as? String ?? "工作台未能启动，请重试连接。"
                guard process.terminationStatus == 0, let status = result?["status"] as? String else { throw NSError(domain:"Cage", code:1, userInfo:[NSLocalizedDescriptionKey:message]) }
                if status == "upgrade_pending" {
                    DispatchQueue.main.async { completion(.success(DesktopEntry(status:status, url:nil, message:message))) }
                    return
                }
                guard let raw = result?["url"] as? String, let url = URL(string: raw), url.scheme == "http", url.host == "localhost", url.port != nil, url.fragment?.isEmpty == false else { throw NSError(domain:"Cage", code:1, userInfo:[NSLocalizedDescriptionKey:message]) }
                DispatchQueue.main.async { completion(.success(DesktopEntry(status:status, url:url, message:""))) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    private func bootstrap(options: [String] = []) {
        loading.stringValue = options.contains("--complete-update") ? "正在停止环境并切换到新版后台…" : "正在启动 VMac 工作台…"
        loading.isHidden = false; retry.isHidden = true; webView.isHidden = true
        completeUpdateButton.isHidden = true; existingEnvironmentButton.isHidden = true
        requestEntry(options: options) { result in
            switch result {
            case .success(let entry):
                self.controllerNeedsUpdate = entry.status != "ready"
                self.completeUpdateMenu.isHidden = !self.controllerNeedsUpdate
                let appTitle = self.workbenchTitle
                self.window.title = self.controllerNeedsUpdate ? "\(appTitle)（更新待完成）" : appTitle
                if let url = entry.url { self.expectedPort = url.port!; self.webView.load(URLRequest(url: url)) }
                else { self.showError(entry.message); self.completeUpdateButton.isHidden = false; self.existingEnvironmentButton.isHidden = false }
            case .failure(let error):
                CageDiagnostics.record("Workbench startup failed: \(error)")
                let message = error.localizedDescription
                if message.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { self.showError(message) }
                else { self.showError("启动工作台失败：本机后台未返回可识别的原因（错误码 \((error as NSError).code)）。请点击“重试连接”；仍失败时请保留此提示并反馈给维护者。") }
            }
        }
    }
    private func browserFile(_ operation: String, id: String, connection: String = "local", path: String? = nil, reply: @escaping (Any?, String?) -> Void) {
        guard UUID(uuidString: id) != nil else { reply(nil,"下载标识无效"); return }
        fileCommand(["browser-file", "--json", "--connection", connection, operation, id] + (path.map { [$0] } ?? []), reply: reply)
    }
    private func clipboardCacheCommand(_ action: String, id: String = "", reply: @escaping (Any?, String?) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["action": action, "cache_id": id]),
              let request = String(data: data, encoding: .utf8) else { reply(nil,"剪贴板缓存请求无效"); return }
        fileCommand(["clipboard-files", "--json", "cache", request], replyLimit: 30 << 20, seconds: 10, reply: reply)
    }
    private func watchClipboardCaches() {
        guard clipboardCacheTimer == nil else { return }
        clipboardCacheTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.collectClipboardCaches() }
        restoreClipboardCaches()
    }
    private func restoreClipboardCaches() {
        clipboardCacheCommand("list") { result, _ in
            self.clipboardCacheLoaded = true
            for selection in (result as? [String:Any])?["selections"] as? [[String:Any]] ?? [] {
                if let id = selection["cache_id"] as? String, let paths = selection["paths"] as? [String], !paths.isEmpty {
                    self.clipboardCopies[id] = paths
                }
            }
            self.collectClipboardCaches()
        }
    }
    private func releaseClipboardCache(_ id: String, completion: @escaping () -> Void = {}) {
        guard !id.isEmpty else { completion(); return }
        clipboardReleasing.insert(id)
        clipboardCacheCommand("release", id: id) { _, error in
            self.clipboardReleasing.remove(id)
            if error == nil { self.clipboardCopies.removeValue(forKey: id) }
            completion()
        }
    }
    private func collectClipboardCaches() {
        guard clipboardCacheLoaded else { return }
        let selected = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL] ?? []).map(\.path)
        let readers = clipboardReaders.values.flatMap { $0 }
        for (id, paths) in clipboardCopies {
            guard !clipboardPending.contains(id), !clipboardReleasing.contains(id), let first = paths.first else { continue }
            let root = URL(fileURLWithPath: first).deletingLastPathComponent().standardizedFileURL.path
            let referenced = (selected + readers).contains { path in
                let path = URL(fileURLWithPath: path).standardizedFileURL.path
                return path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
            }
            if !referenced { releaseClipboardCache(id) }
        }
    }
    private func fileCommand(_ arguments: [String], replyLimit: Int = 65536, seconds: TimeInterval = 1800, reply: @escaping (Any?, String?) -> Void) {
        guard let executable = Bundle.main.url(forResource: CageProfile.backendName, withExtension: nil) else { reply(nil,"无法找到文件传递组件"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); process.executableURL = executable
            process.arguments = arguments
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
                defer { timeout.cancel() }
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard data.count <= replyLimit, let result = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw CageUpdateError("文件操作未返回有效结果") }
                DispatchQueue.main.async { reply(process.terminationStatus == 0 ? result : nil, process.terminationStatus == 0 ? nil : result["message"] as? String ?? "文件操作失败") }
            } catch { CageDiagnostics.record(error.localizedDescription); DispatchQueue.main.async { reply(nil,error.localizedDescription) } }
        }
    }
    private func guestDesktopCommand(_ reply: @escaping (Any?, String?) -> Void) {
        guard let binary = Bundle.main.url(forResource: CageProfile.backendName, withExtension: nil) else { reply(nil, "无法找到客机控制组件"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = binary
            task.arguments = ["agent", "request", "POST", "/api/macos/login", "--input", "-"]
            let input = Pipe(), output = Pipe()
            task.standardInput = input; task.standardOutput = output; task.standardError = FileHandle.nullDevice
            var failure: String?
            do {
                try task.run()
                try input.fileHandleForWriting.write(contentsOf: Data("{\"action\":\"show-native-desktop\"}".utf8))
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let response = envelope?["data"] as? [String: Any]
                let body = response?["body"] as? [String: Any]
                failure = (body?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if task.terminationStatus != 0 || body == nil {
                    failure = (envelope?["error"] as? [String: Any])?["message"] as? String ?? "原生客机桌面暂不可用"
                }
            } catch { failure = "原生客机桌面暂不可用" }
            DispatchQueue.main.async {
                if let failure { reply(nil, failure); return }
                self.fadeGuestContent()
                self.guestDesktopVisible = true
                self.webView.isHidden = true
                self.shell.desktopPresented()
                self.applyShell(animated: true)
                CageDiagnostics.record("Embedded guest view presented in window \(self.window.windowNumber)")
                reply(true, nil)
            }
        }
    }
    private func rememberFiles(_ urls: [URL]) throws -> [String: Any] {
        guard !urls.isEmpty, urls.count <= 100 else { throw CageUpdateError("请选择 1 至 100 个文件") }
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw CageUpdateError("请选择本机文件") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CageUpdateError("请选择普通文件，暂不支持文件夹或链接") }
            guard let size = values.fileSize, size <= 2 * 1024 * 1024 * 1024 else { throw CageUpdateError("每个文件不能超过 2 GB") }
        }
        let now = Date()
        fileSelections = fileSelections.filter { $0.value.expires > now }
        if fileSelections.count >= 16, let oldest = fileSelections.min(by: { $0.value.expires < $1.value.expires }) { fileSelections.removeValue(forKey: oldest.key) }
        let id = UUID().uuidString
        fileSelections[id] = (urls.map(\.path), now.addingTimeInterval(600))
        return ["fileSelection": id, "count": urls.count]
    }
    private func showError(_ text: String) { CageDiagnostics.record(text); loading.stringValue = text; loading.isHidden = false; retry.isHidden = false; webView.isHidden = true }
    private func applyAppearance(_ value: [String:Any]) {
        if nativeVMWorkbench {
            NSApp.appearance = vmacAppearance
            window.backgroundColor = CagePalette.paper
            window.isOpaque = true
            backdrop.isHidden = true
            loading.textColor = CagePalette.ink
            return
        }
        let mode = value["mode"] as? String ?? "system"
        NSApp.appearance = mode == "system" ? nil : NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        let translucent = value["translucent"] as? Bool ?? false
        backdrop.isHidden = !translucent
        window.isOpaque = !translucent
        let background = value["background"] as? String ?? "#f7f7f7"
        let hex = UInt32(background.dropFirst(), radix: 16) ?? 0xf7f7f7
        window.backgroundColor = NSColor(srgbRed: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, alpha: 1)
        loading.textColor = .labelColor
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading.isHidden = true; retry.isHidden = true; completeUpdateButton.isHidden = true; existingEnvironmentButton.isHidden = true; webView.isHidden = false; window.makeFirstResponder(webView); publishWindowVisibility() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        CageDiagnostics.record("Workbench navigation failed: \(error)")
        let failure = error as NSError
        let reason: String
        switch failure.code {
        case NSURLErrorTimedOut: reason = "等待本机后台响应超时"
        case NSURLErrorCannotConnectToHost: reason = "本机后台没有接受连接，可能尚未启动或已经退出"
        case NSURLErrorNetworkConnectionLost: reason = "本机工作台连接在加载完成前中断"
        default: reason = "内置网页组件未能加载本机工作台（错误码 \(failure.code)）"
        }
        showError("打开工作台失败：\(reason)。请点击“重试连接”；仍失败时请保留此错误提示并反馈给维护者。后台任务不会因此自动结束。")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        CageDiagnostics.record("WebKit content process terminated"); bootstrap()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "http", url.host == "localhost", url.port == expectedPort else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "http", origin.host == "localhost", origin.port == expectedPort, let body = message.body as? [String:Any], let action = body["action"] as? String else { replyHandler(nil,"请求来源无效"); return }
        switch action {
        case "remoteInput":
            replyHandler(nativeInput.handle(body), nil)
        case "accountDevice":
            guard !controllerNeedsUpdate, !accountDeviceBusy,
                  let operation = body["operation"] as? String, ["status", "enable", "disable", "unlock"].contains(operation) else { replyHandler(nil,"账户操作正在进行或后台需要更新，请稍后重试"); return }
            accountDeviceBusy = true
            let kind = body["kind"] as? String
            let connection = body["connection_id"] as? String ?? "local"
            requestEntry { result in
                guard case .success(let entry) = result, let url = entry.url else {
                    self.accountDeviceBusy = false; replyHandler(nil,"无法连接本地账户，请重新打开 VMac"); return
                }
                Task.detached {
                    do {
                        let client = try CageAccountDevice(entry: url, connection: connection)
                        let value = try await client.handle(operation: operation, kind: kind)
                        await MainActor.run { self.accountDeviceBusy = false; replyHandler(value,nil) }
                    } catch {
                        await MainActor.run { self.accountDeviceBusy = false; replyHandler(nil,error.localizedDescription) }
                    }
                }
            }
        case "exportDiagnostics":
            guard !nativeFilePanelOpen else { replyHandler(nil,"请先完成当前文件窗口"); return }
            let panel = NSSavePanel(); panel.title = "导出诊断包"; panel.nameFieldStringValue = "cage-diagnostics.zip"
            panel.allowedContentTypes = [.zip]; nativeFilePanelOpen = true
            panel.beginSheetModal(for: window) { response in
                self.nativeFilePanelOpen = false
                guard response == .OK, let url = panel.url else { replyHandler(["canceled":true],nil); return }
                self.fileCommand(["diagnostics", "--json", "--connection", body["connection_id"] as? String ?? "local", url.path], reply: replyHandler)
            }
        case "showGuestDesktop":
            guard nativeVMWorkbench else { replyHandler(nil, "此版本不支持原生客机工作台"); return }
            guestSidebar?.select("desktop")
            guestDesktopCommand(replyHandler)
        case "vmacProfiles":
            guard nativeVMWorkbench else { replyHandler(nil, "需要 VMac 本机工作台"); return }
            replyHandler(CageProfile.profileList(), nil)
        case "vmacCreateProfile":
            guard nativeVMWorkbench, let raw = body["name"] as? String else { replyHandler(nil, "虚拟机名称无效"); return }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var profiles = CageProfile.savedProfiles
            guard !name.isEmpty, name.count <= 36, profiles.count < 20,
                  !profiles.values.contains(name) else { replyHandler(nil, "名称为空、重复，或已达到虚拟机数量上限"); return }
            var id = String(UUID().uuidString.lowercased().prefix(8))
            while profiles[id] != nil || FileManager.default.fileExists(atPath: CageProfile.profileFolder(id).path) {
                id = String(UUID().uuidString.lowercased().prefix(8))
            }
            profiles[id] = name
            UserDefaults.standard.set(profiles, forKey: "vmac.guestProfiles")
            replyHandler(CageProfile.profileList(), nil)
        case "vmacSwitchProfile":
            guard nativeVMWorkbench, let id = body["id"] as? String,
                  CageProfile.profileExists(id), id != CageProfile.activeProfile else { replyHandler(nil, "虚拟机选项无效"); return }
            fileCommand(["agent", "call", "status"], seconds: 5) { [weak self] result, _ in
                guard let self, let response = result as? [String: Any], let current = response["data"] as? [String: Any],
                      current["vm_running"] as? Bool == false,
                      (current["job"] as? [String: Any])?["running"] as? Bool != true else {
                    replyHandler(nil, "请先完成当前客机操作并停止客机")
                    return
                }
                self.relaunchVMac(profile: id, reply: replyHandler)
            }
        case "guestNavigationStatus":
            guard nativeVMWorkbench else { replyHandler(nil, "此版本不支持原生客机工作台"); return }
            if let destination = body["destination"] as? String { guestSidebar?.select(destination) }
            guestSidebar?.update(running: body["running"] as? Bool ?? false,
                ready: body["ready"] as? Bool ?? false, busy: body["busy"] as? Bool ?? false,
                networkLabel: body["network"] as? String ?? "", failed: body["failed"] as? Bool ?? false,
                setup: body["setup"] as? Bool ?? false, activity: body["activity"] as? String ?? "")
            vmacToolbar?.update(VMacStatus(name: activeProfileName(), tone: body["tone"] as? String ?? "idle",
                                           detail: body["detail"] as? String ?? ""))
            let running = body["running"] as? Bool ?? false, ready = body["ready"] as? Bool ?? false
            vmacToolbar?.setGuestActions(VMacGuestActions(running: running, ready: ready))
            // A desktop that is already showing stays up for as long as the guest runs.
            shell.guestStatusChanged(ready: running && (ready || guestDesktopVisible))
            if shell.mode == .controlCenter && guestDesktopVisible { showGuestControls() } else { applyShell(animated: true) }
            replyHandler(true, nil)
        case "guestTrafficStatus":
            guard nativeVMWorkbench else { replyHandler(nil, "此版本不支持原生客机工作台"); return }
            guestSidebar?.updateTraffic(body)
            replyHandler(true, nil)
        case "showGuestControls":
            guard nativeVMWorkbench else { replyHandler(nil, "此版本不支持原生客机工作台"); return }
            showGuestControls()
            replyHandler(true, nil)
        case "workbenchReady":
            guard !controllerNeedsUpdate else { replyHandler(nil,"后台版本尚未同步，更新未完成"); return }
            appUpdater?.markLaunchReady()
            replyHandler(true,nil)
        case "appReference":
            let repository = Bundle.main.bundleIdentifier == CageProfile.vmacBundleID ? "Ray-hola/Vmac" : "Lee-xeo/Claude-Cage"
            guard !nativeVMWorkbench || Bundle.main.bundleIdentifier == CageProfile.vmacBundleID else { replyHandler(nil, "此测试版使用独立安装包"); return }
            let path: String
            switch body["kind"] as? String {
            case "source": path = "commits/main"
            case "releases": path = "releases"
            default: replyHandler(nil,"未知的项目页面"); return
            }
            let opened = NSWorkspace.shared.open(URL(string: "https://github.com/\(repository)/" + path)!)
            replyHandler(opened ? true : nil, opened ? nil : "无法打开项目页面，请检查默认浏览器")
        case "appUpdate":
            if nativeVMTest && Bundle.main.bundleIdentifier != CageProfile.vmacBundleID { replyHandler(nil, "原生 VM 测试版使用独立构建。"); return }
            guard let operation = body["operation"] as? String, ["status", "check", "install", "cancel"].contains(operation) else { replyHandler(nil,"更新操作无效"); return }
            replyHandler(appUpdater.handle(operation),nil)
        case "appearance":
            guard let mode = body["mode"] as? String, ["system", "light", "dark"].contains(mode), let background = body["background"] as? String, background.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { replyHandler(nil,"外观参数无效"); return }
            let value: [String:Any] = ["mode":mode,"background":background,"translucent":body["translucent"] as? Bool ?? false]
            UserDefaults.standard.set(value, forKey: nativeVMWorkbench ? "vmac.windowAppearance" : "cage.windowAppearance")
            applyAppearance(value)
            replyHandler(true,nil)
        case "clipboardRead": replyHandler(NSPasteboard.general.string(forType:.string) ?? "",nil)
        case "clipboardRevision": watchClipboardCaches(); replyHandler(NSPasteboard.general.changeCount,nil)
        case "clipboardSyncCancel": clipboardGeneration += 1; replyHandler(true,nil)
        case "clipboardSyncRelease":
            guard let id = body["files"] as? String, UUID(uuidString: id) != nil else { replyHandler(nil,"剪贴板文件标识无效"); return }
            fileCommand(["clipboard-files", "--json", "--connection", body["connection_id"] as? String ?? "local", "release", id], reply: replyHandler)
        case "clipboardSyncRead":
            watchClipboardCaches()
            let board = NSPasteboard.general
            let revision = board.changeCount
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL], !urls.isEmpty {
                if nativeVMTest { replyHandler(["revision":revision,"text":""],nil); return }
                let reader = UUID(), generation = clipboardGeneration
                clipboardReaders[reader] = urls.map(\.path)
                fileCommand(["clipboard-files", "--json", "--connection", body["connection_id"] as? String ?? "local", "send"] + urls.map(\.path)) { result, error in
                    defer { self.clipboardReaders.removeValue(forKey: reader); self.collectClipboardCaches() }
                    guard error == nil, var payload = result as? [String:Any] else { replyHandler(nil,error ?? "剪贴板文件传递失败"); return }
                    if generation != self.clipboardGeneration || board.changeCount != revision, let id = payload["files"] as? String {
                        self.fileCommand(["clipboard-files", "--json", "--connection", body["connection_id"] as? String ?? "local", "release", id]) { _, _ in }
                    }
                    payload["revision"] = revision
                    replyHandler(payload,nil)
                }
            } else if let image = NSImage(pasteboard:board), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff) {
                guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0, bitmap.pixelsWide <= 40_000_000 / bitmap.pixelsHigh,
                      let png = bitmap.representation(using:.png,properties:[:]), png.count <= 20 * 1024 * 1024 else { replyHandler(nil,"图片不能超过 20 MB 或 4000 万像素"); return }
                replyHandler(["revision":revision,"png":png.base64EncodedString()],nil)
            } else { replyHandler(["revision":revision,"text":board.string(forType:.string) ?? ""],nil) }
        case "clipboardSyncWrite":
            watchClipboardCaches()
            let board = NSPasteboard.general
            let generation = clipboardGeneration
            let expected = body["revision"] as? Int
            let write: ([URL]?, String) -> Void = { urls, cache in
                guard generation == self.clipboardGeneration, expected == nil || board.changeCount == expected else {
                    self.clipboardPending.remove(cache)
                    self.releaseClipboardCache(cache) { replyHandler(["superseded":true,"revision":board.changeCount],nil) }
                    return
                }
                defer { self.clipboardPending.remove(cache); self.collectClipboardCaches() }
                var written = false
                if let urls {
                    board.clearContents(); written = board.writeObjects(urls as [NSURL])
                } else if let encoded = body["png"] as? String, let data = Data(base64Encoded:encoded), data.count <= 20 * 1024 * 1024,
                          let bitmap = NSBitmapImageRep(data:data), bitmap.pixelsHigh > 0, bitmap.pixelsWide > 0,
                          bitmap.pixelsWide <= 40_000_000 / bitmap.pixelsHigh {
                    let image = NSImage(size:bitmap.size); image.addRepresentation(bitmap)
                    board.clearContents(); written = board.writeObjects([image])
                } else if let text = body["text"] as? String, text.utf8.count <= 2 * 1024 * 1024 {
                    board.clearContents(); written = board.setString(text,forType:.string)
                } else { replyHandler(nil,"剪贴板内容格式或大小无效"); return }
                guard written else { replyHandler(nil,"剪贴板写入失败"); return }
                if !cache.isEmpty { self.clipboardCacheCommand("publish", id: cache) { _, _ in } }
                replyHandler(["revision":board.changeCount],nil)
            }
            if let id = body["files"] as? String, UUID(uuidString:id) != nil {
                fileCommand(["clipboard-files","--json","--connection",body["connection_id"] as? String ?? "local","receive",id]) { result, error in
                    guard error == nil, let paths = (result as? [String:Any])?["paths"] as? [String] else { self.restoreClipboardCaches(); replyHandler(nil,error ?? "剪贴板文件读取失败"); return }
                    let cache = (result as? [String:Any])?["cache_id"] as? String ?? ""
                    if !cache.isEmpty { self.clipboardCopies[cache] = paths; self.clipboardPending.insert(cache) }
                    write(paths.map { URL(fileURLWithPath:$0) }, cache)
                }
            } else { write(nil, "") }
        case "clipboardReadContent":
            let board = NSPasteboard.general
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                if nativeVMTest { replyHandler(["text":""],nil); return }
                do { replyHandler(try rememberFiles(urls), nil) }
                catch { replyHandler(nil, error.localizedDescription) }
            } else if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff) {
                guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                      bitmap.pixelsWide <= 40_000_000 / bitmap.pixelsHigh,
                      let png = bitmap.representation(using: .png, properties: [:]), png.count <= 20 * 1024 * 1024 else {
                    replyHandler(nil,"图片不能超过 20 MB 或 4000 万像素"); return
                }
                replyHandler(["png":png.base64EncodedString()],nil)
            } else { replyHandler(["text":board.string(forType:.string) ?? ""],nil) }
        case "chooseGuestMedia":
            guard !nativeFilePanelOpen else { replyHandler(nil,"请先完成当前文件窗口"); return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
            panel.title = "选择 Apple 恢复镜像"; nativeFilePanelOpen = true
            panel.beginSheetModal(for: window) { response in
                self.nativeFilePanelOpen = false
                replyHandler(response == .OK ? (panel.url?.path ?? "") : "", nil)
            }
        case "chooseUploadFiles":
            guard !nativeFilePanelOpen else { replyHandler(nil,"请先完成当前文件窗口"); return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false; panel.canChooseFiles = true
            panel.allowsMultipleSelection = body["multiple"] as? Bool ?? false
            panel.title = "选择本机文件"; panel.prompt = "选择"
            nativeFilePanelOpen = true
            panel.beginSheetModal(for: window) { response in
                self.nativeFilePanelOpen = false
                guard response == .OK else { replyHandler(["canceled":true],nil); return }
                do { replyHandler(try self.rememberFiles(panel.urls), nil) }
                catch { replyHandler(nil, error.localizedDescription) }
            }
        case "uploadHostFiles":
            guard let selection = body["selection"] as? String,
                  let target = body["target"] as? String, ["browser", "desktop", "terminal"].contains(target),
                  let id = body["id"] as? String, (target == "terminal" ? id.range(of: "^[a-f0-9]{16}$", options: .regularExpression) != nil : UUID(uuidString: id) != nil),
                  let files = fileSelections.removeValue(forKey: selection), files.expires > Date() else {
                replyHandler(nil,"文件选择已过期，请重新复制或选择文件"); return
            }
            fileCommand(["upload-files", "--json", "--connection", body["connection_id"] as? String ?? "local", target, id] + files.paths, reply: replyHandler)
        case "clipboardWrite":
            guard let text = body["text"] as? String else { replyHandler(nil,"缺少文本"); return }
            if body["confidential"] as? Bool == true {
                do {
                    try MacGuestLoginCredential.copyToClipboard(text)
                    replyHandler(true,nil)
                } catch {
                    replyHandler(nil,error.localizedDescription)
                }
                return
            }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType:.string); replyHandler(true,nil)
        case "saveBrowserDownload":
            guard !nativeFilePanelOpen, let id = body["id"] as? String, UUID(uuidString:id) != nil else { replyHandler(nil,"请先完成当前文件窗口"); return }
            let panel = NSSavePanel(); panel.canCreateDirectories = true
            panel.nameFieldStringValue = ((body["name"] as? String ?? "download") as NSString).lastPathComponent
            panel.prompt = "保存"; panel.title = "将下载另存为到本机"
            nativeFilePanelOpen = true
            panel.beginSheetModal(for: window) { response in
                self.nativeFilePanelOpen = false
                guard response == .OK, let url = panel.url else { replyHandler(["canceled":true],nil); return }
                self.browserFile("save",id:id,connection:body["connection_id"] as? String ?? "local",path:url.path,reply:replyHandler)
            }
        case "desktopFileAction":
            guard let id = body["id"] as? String, UUID(uuidString:id) != nil else { replyHandler(nil,"文件打开标识无效"); return }
            fileCommand(["desktop-file", "--json", "--connection", body["connection_id"] as? String ?? "local", id], reply: replyHandler)
        case "browserDownloadAction":
            guard let id = body["id"] as? String, let operation = body["operation"] as? String, ["open","reveal"].contains(operation) else { replyHandler(nil,"下载操作无效"); return }
            browserFile(operation,id:id,connection:body["connection_id"] as? String ?? "local",reply:replyHandler)
        case "importTheme":
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "导入主题"
            nativeFilePanelOpen = true
            panel.beginSheetModal(for: window) { response in
                self.nativeFilePanelOpen = false
                guard response == .OK, let url = panel.url else { replyHandler("", nil); return }
                do {
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let data = try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
                    guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8) else { replyHandler(nil, "请选择不超过 256 KB 的 UTF-8 JSON 主题文件"); return }
                    replyHandler(text, nil)
                } catch { replyHandler(nil, "无法读取主题文件，请检查文件权限") }
            }
        case "saveRecoveryKey":
            guard !nativeFilePanelOpen else { replyHandler(nil, "请先完成当前文件窗口"); return }
            guard let key = body["key"] as? String, key.utf8.count == 71,
                  key.range(of: "^[A-F0-9]{8}(-[A-F0-9]{8}){7}$", options: .regularExpression) != nil,
                  let data = (key + "\n").data(using: .utf8) else { replyHandler(nil, "恢复密钥格式无效"); return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.canCreateDirectories = true
            panel.nameFieldStringValue = "账户恢复密钥.txt"; panel.prompt = "保存"; panel.title = "保存账户恢复密钥"
            nativeFilePanelOpen = true
            panel.beginSheetModal(for: window) { response in
                self.nativeFilePanelOpen = false
                guard response == .OK, let url = panel.url else { replyHandler(false, nil); return }
                do {
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    replyHandler(true, nil)
                } catch { replyHandler(nil, "恢复密钥未能保存，请检查保存位置的权限") }
            }
        case "exportTheme":
            guard let text = body["text"] as? String, let data = text.data(using: .utf8), data.count <= 256 * 1024,
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any], document["format"] as? String == "cage-theme", document["version"] as? Int == 1 else { replyHandler(nil, "主题文件格式无效"); return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
            let filename = (body["filename"] as? String ?? "VMac.cage-theme.json") as NSString
            panel.nameFieldStringValue = filename.lastPathComponent; panel.prompt = "导出主题"
            nativeFilePanelOpen = true
            panel.beginSheetModal(for: window) { response in
                self.nativeFilePanelOpen = false
                guard response == .OK, let url = panel.url else { replyHandler(false, nil); return }
                do { try data.write(to: url, options: .atomic); replyHandler(true, nil) }
                catch { replyHandler(nil, "主题未能导出，请检查保存位置的权限") }
            }
        case "shareLocalProject":
            guard !nativeFilePanelOpen, let connection = body["connection_id"] as? String,
                  !connection.isEmpty, let mode = body["mode"] as? String, ["read","write"].contains(mode)
            else { replyHandler(nil,"请在云端工作台重新选择项目"); return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
            panel.prompt = mode == "write" ? "允许云端读写" : "允许云端读取"
            panel.message = mode == "write" ? "云端 VMac 可以读取、修改和删除所选项目中的文件。" : "云端 VMac 可以读取所选项目中的文件。"
            nativeFilePanelOpen = true
            panel.beginSheetModal(for: window) { response in
                self.nativeFilePanelOpen = false
                guard response == .OK, let url = panel.url else { replyHandler(["canceled":true],nil); return }
                self.fileCommand(["share-project", "--json", "--connection", connection, mode, url.path], reply: replyHandler)
            }
        case "chooseFolder":
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
            let storage = (body["purpose"] as? String) == "environmentStorage"
            panel.prompt = storage ? "选择文件夹" : "共享此项目"
            panel.message = storage ? "请选择用于保存镜像和虚拟磁盘的空文件夹。" : "仅此文件夹会与 VMac 共享。请选择具体项目。"
            nativeFilePanelOpen = true
            panel.beginSheetModal(for:window) { response in self.nativeFilePanelOpen = false; replyHandler(response == .OK ? panel.url?.path : "",nil) }
        case "refreshSession":
            requestEntry(options: controllerNeedsUpdate ? ["--existing"] : []) { result in
                switch result {
                case .success(let entry):
                    if let url = entry.url { replyHandler(["url":url.absoluteString],nil) }
                    else { replyHandler(nil,entry.message) }
                case .failure: replyHandler(nil,"工作台会话恢复失败，请重新连接后重试。")
                }
            }
        case "reconnect": replyHandler(true,nil); bootstrap()
        case "quitNow": replyHandler(true,nil); allowQuit = true; NSApp.terminate(nil)
        default: replyHandler(nil,"未知操作")
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { let alert = NSAlert(); alert.messageText = message; alert.beginSheetModal(for:window){_ in completionHandler()} }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let origin = frame.securityOrigin
        guard frame.isMainFrame, origin.protocol == "http", origin.host == "localhost", origin.port == expectedPort, !nativeFilePanelOpen else { completionHandler(nil); return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.title = "选择本机文件"; nativeFilePanelOpen = true
        panel.beginSheetModal(for: window) { response in
            self.nativeFilePanelOpen = false
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消"); alert.beginSheetModal(for:window){completionHandler($0 == .alertFirstButtonReturn)} }
    private func publishWindowVisibility(forceHidden: Bool = false) {
        guard window != nil, webView != nil else { return }
        let visible = !forceHidden && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        #if CAGE_EMBEDDED_VM
        if nativeVMWorkbench {
            _ = (visible && guestDesktopVisible ? "clipboard-visible" : "clipboard-hidden").withCString { performEmbeddedUtility($0) }
        }
        #endif
        webView.evaluateJavaScript("window.cageWindowVisible = \(visible ? "true" : "false"); window.dispatchEvent(new Event('cage-window-visibility'));", completionHandler: nil)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { publishWindowVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { publishWindowVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { publishWindowVisibility() }
    func windowWillClose(_ notification: Notification) { publishWindowVisibility(forceHidden: true) }
    func applicationDidHide(_ notification: Notification) { publishWindowVisibility(forceHidden: true) }
    func applicationDidUnhide(_ notification: Notification) { publishWindowVisibility() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if nativeVMWorkbench && guestDesktopVisible {
            guestDesktopCommand { _, error in
                if error != nil { self.showGuestControls() }
            }
            return false
        }
        window.makeKeyAndOrderFront(nil)
        publishWindowVisibility()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { appUpdater?.cancelForTermination() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowQuit || (webView.isHidden && !guestDesktopVisible) || appUpdater?.awaitingInitialWorkbench == true {
            if appUpdater?.prepareForTermination({ NSApp.reply(toApplicationShouldTerminate: true) }) == true { return .terminateLater }
            return .terminateNow
        }
        if guestDesktopVisible { showGuestControls() }
        window.makeKeyAndOrderFront(nil); action("quit"); return .terminateCancel
    }
}
