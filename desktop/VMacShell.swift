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

/// How wide the sidebar may be. The divider drags it from a rail of icons to
/// a full list, and the page beside it always keeps room to be read.
enum VMacSidebarWidth {
    static let rail: CGFloat = 64, widest: CGFloat = 260, standard: CGFloat = 220
    static let pageMinimum: CGFloat = 600
    static func widest(in windowWidth: CGFloat) -> CGFloat { min(widest, windowWidth - pageMinimum) }
    /// A saved width, brought back into range; the standard width when none is saved.
    static func restored(_ saved: Double?) -> CGFloat { min(widest, max(rail, saved.map { CGFloat($0) } ?? standard)) }
    /// Only a width the divider can reach is worth saving.
    static func remembers(_ width: CGFloat) -> Bool { width >= rail && width <= widest }
}

/// The guests VMac created besides the first one. Each is a folder under
/// `vms` named by eight hex digits, with its name kept in the preferences.
/// The first guest is not among them: its folder is the product folder
/// itself, with the shared account and every other guest inside, so it is
/// never removed.
struct VMacGuestSlots {
    enum Failure: Error { case notRemovable, stillClosing }
    static let namesKey = "vmac.guestProfiles"
    /// Carries a removed guest's name inside its folder, so that a folder
    /// put back from the Trash can be listed again.
    static let nameFile = "removed-guest-name"
    let root: URL
    let defaults: UserDefaults

    var names: [String: String] { defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:] }
    func folder(_ id: String) -> URL { root.appendingPathComponent("vms").appendingPathComponent(id) }
    /// An id VMac made; nothing else may name a folder to remove.
    static func isSlot(_ id: String) -> Bool { id.range(of: "^[a-f0-9]{8}$", options: .regularExpression) != nil }
    /// A guest can go when VMac lists it and it is not the one in use.
    func removable(_ id: String, active: String) -> Bool { Self.isSlot(id) && names[id] != nil && id != active }
    /// Whether a controller still holds the guest's lock: a VMac that was
    /// showing it and has not finished closing.
    func busy(_ id: String) -> Bool {
        let descriptor = open(folder(id).appendingPathComponent("control.lock").path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }
    /// What the guest's folder takes on disk. A disk image counts for what
    /// it has written, not for its nominal size.
    func size(_ id: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let found = FileManager.default.enumerator(at: folder(id), includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in found {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
    /// Hands the guest's folder to `trash` and forgets its name. A guest that
    /// was never opened has no folder, and only its name goes.
    func remove(_ id: String, active: String, trash: (URL) throws -> Void) throws {
        guard removable(id, active: active) else { throw Failure.notRemovable }
        guard !busy(id) else { throw Failure.stillClosing }
        var names = names
        let folder = folder(id), marker = folder.appendingPathComponent(Self.nameFile)
        if FileManager.default.fileExists(atPath: folder.path) {
            try Data((names[id] ?? "").utf8).write(to: marker, options: .atomic)
            do { try trash(folder) } catch {
                try? FileManager.default.removeItem(at: marker)
                throw error
            }
        }
        names[id] = nil
        defaults.set(names, forKey: Self.namesKey)
    }
    /// Lists again every guest whose folder has come back from the Trash. A
    /// name taken in the meantime gets a number.
    func adoptRestored() {
        guard let found = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("vms"), includingPropertiesForKeys: nil) else { return }
        var names = names, changed = false
        for folder in found where Self.isSlot(folder.lastPathComponent) && names[folder.lastPathComponent] == nil {
            let marker = folder.appendingPathComponent(Self.nameFile)
            guard let data = try? Data(contentsOf: marker), let saved = String(data: data, encoding: .utf8),
                  !saved.isEmpty, saved.count <= 36 else { continue }
            var name = saved, number = 2
            while names.values.contains(name) { name = "\(saved) \(number)"; number += 1 }
            names[folder.lastPathComponent] = name
            changed = true
            try? FileManager.default.removeItem(at: marker)
        }
        if changed { defaults.set(names, forKey: Self.namesKey) }
    }
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
