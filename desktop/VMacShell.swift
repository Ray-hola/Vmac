import AppKit

/// The window shows either the guest desktop or the control center.
enum VMacShellMode: Equatable { case desktop, controlCenter }
enum VMacShellAction: Equatable { case showDesktop, showControlCenter, none }

/// Decides which of the two the window shows. It holds no views, so the rules
/// can be tested on their own.
struct VMacShellState: Equatable {
    private(set) var mode: VMacShellMode = .controlCenter
    private(set) var guestReady = false

    /// A guest that stops being ready has no picture to show.
    mutating func guestStatusChanged(ready: Bool) {
        guestReady = ready
        if !ready { mode = .controlCenter }
    }
    mutating func desktopPresented() { mode = .desktop }
    mutating func controlsRequested() { mode = .controlCenter }
    func toggleAction() -> VMacShellAction {
        if mode == .desktop { return .showControlCenter }
        return guestReady ? .showDesktop : .none
    }
    var sidebarVisible: Bool { mode == .controlCenter }
}

enum VMacTone: String { case busy, ok, warn, bad, idle }

/// What the toolbar's status pill shows. With the window title hidden, the
/// pill is also where an unfinished update is mentioned.
struct VMacStatus: Equatable {
    let tone: VMacTone
    let title: String
    let detail: String
    init(name: String, tone: String, detail: String, updatePending: Bool = false) {
        self.tone = VMacTone(rawValue: tone) ?? .idle
        self.title = name
        self.detail = updatePending ? (detail.isEmpty ? "更新待完成" : detail + " · 更新待完成") : detail
    }
}

/// The lines of the popover behind the status pill. A field the page did not
/// send reads as a dash.
struct VMacStatusDetail: Equatable {
    let network: String
    let exit: String
    let disk: String
    init(network: String, exit: String, disk: String) {
        self.network = network; self.exit = exit; self.disk = disk
    }
    init(body: [String: Any]) {
        func text(_ key: String) -> String {
            guard let value = body[key] as? String, !value.isEmpty else { return "—" }
            return value
        }
        self.init(network: text("network"), exit: text("exit"), disk: text("disk"))
    }
}

/// Which toolbar actions a guest in this state can take. Sending files needs
/// a guest that is ready; restarting or stopping only needs it to be running,
/// so a guest stuck while connecting can still be dealt with.
struct VMacGuestActions: Equatable {
    let upload: Bool
    let lifecycle: Bool
    init(running: Bool, ready: Bool) {
        upload = running && ready
        lifecycle = running
    }
}

/// The switches of the sharing page. Each is stored in the app's defaults and
/// counts as on until it is turned off.
enum VMacPreference: String, CaseIterable {
    case shareClipboardContent, hostInputMethod, fileDrop

    var defaultsKey: String { "vmac." + rawValue }
    func value(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }
    func set(_ value: Bool, in defaults: UserDefaults) { defaults.set(value, forKey: defaultsKey) }
    static func all(in defaults: UserDefaults) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.value(in: defaults)) })
    }
}

/// The line between the sidebar and the content is the faintest hairline;
/// the sidebar's own tint does most of the dividing.
final class VMacSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        NSColor(white: 0, alpha: 0.06).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
    }
}

enum VMacToastKind { case info, error }

/// The rules for the toast over the guest. An error stays until it is
/// dismissed or replaced; an ordinary notice hides itself.
struct VMacToastModel {
    private(set) var text = ""
    private(set) var kind = VMacToastKind.info
    var visible: Bool { !text.isEmpty }

    /// Seconds until the toast hides itself; nil when it stays as it is.
    mutating func show(_ text: String, kind: VMacToastKind) -> TimeInterval? {
        if text.isEmpty {
            if self.kind != .error { self.text = "" }
            return nil
        }
        self.text = text
        self.kind = kind
        return kind == .error ? nil : 3
    }
    mutating func dismiss() { text = ""; kind = .info }
}

/// In full screen the guest owns the whole display: the menu bar and the
/// toolbar stay away until the pointer reaches the top edge.
func vmacFullScreenOptions() -> NSApplication.PresentationOptions {
    [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
}

enum VMacMenuKey { case quit, hide, minimize, settings, controlCenter, fullScreen }

/// On the guest desktop VMac keeps only two shortcuts, so that every other
/// key combination reaches the guest like it would on a real Mac. A window
/// that is closed or minimized shows no guest, so the Mac shortcuts work again.
enum VMacMenuKeys {
    static func equivalent(for key: VMacMenuKey, mode: VMacShellMode, windowVisible: Bool) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        let guestHasKeys = mode == .desktop && windowVisible
        switch key {
        case .controlCenter: return (",", [.control, .command])
        case .fullScreen: return ("f", [.control, .command])
        case .quit: return guestHasKeys ? ("", []) : ("q", [.command])
        case .hide: return guestHasKeys ? ("", []) : ("h", [.command])
        case .minimize: return guestHasKeys ? ("", []) : ("m", [.command])
        case .settings: return guestHasKeys ? ("", []) : (",", [.command])
        }
    }
}
