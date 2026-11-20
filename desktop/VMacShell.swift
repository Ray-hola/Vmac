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

/// What the toolbar's status pill shows.
struct VMacStatus: Equatable {
    let tone: VMacTone
    let title: String
    let detail: String
    init(name: String, tone: String, detail: String) {
        self.tone = VMacTone(rawValue: tone) ?? .idle
        self.title = name
        self.detail = detail
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

/// The saved appearance choice as a window appearance; nil follows the system.
func vmacAppearanceName(for setting: String?) -> NSAppearance.Name? {
    switch setting {
    case "light": return .aqua
    case "dark": return .darkAqua
    default: return nil
    }
}

/// The appearance saved by the settings page ("mode": system, light or dark).
func vmacAppearanceName(forSaved appearance: [String: Any]) -> NSAppearance.Name? {
    vmacAppearanceName(for: appearance["mode"] as? String)
}

/// In full screen the guest owns the whole display: the menu bar and the
/// toolbar stay away until the pointer reaches the top edge.
func vmacFullScreenOptions() -> NSApplication.PresentationOptions {
    [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
}

enum VMacMenuKey { case quit, hide, minimize, settings, controlCenter, fullScreen }

/// On the guest desktop VMac keeps only two shortcuts, so that every other
/// key combination reaches the guest like it would on a real Mac.
enum VMacMenuKeys {
    static func equivalent(for key: VMacMenuKey, mode: VMacShellMode) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        switch key {
        case .controlCenter: return (",", [.control, .command])
        case .fullScreen: return ("f", [.control, .command])
        case .quit: return mode == .desktop ? ("", []) : ("q", [.command])
        case .hide: return mode == .desktop ? ("", []) : ("h", [.command])
        case .minimize: return mode == .desktop ? ("", []) : ("m", [.command])
        case .settings: return mode == .desktop ? ("", []) : (",", [.command])
        }
    }
}
