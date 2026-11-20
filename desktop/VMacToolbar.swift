import Cocoa

/// The status pill in the middle of the toolbar: a dot and "guest · state".
private final class VMacStatusPill: NSView {
    var onClick: (() -> Void)?
    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var status = VMacStatus(name: "", tone: "idle", detail: "")
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: min(360, label.intrinsicContentSize.width + 38), height: 24)
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        dot.frame = NSRect(x: 11, y: (bounds.height - 7) / 2, width: 7, height: 7)
        dot.cornerRadius = 3.5
        label.frame = NSRect(x: 25, y: (bounds.height - label.intrinsicContentSize.height) / 2,
                             width: max(0, bounds.width - 37), height: label.intrinsicContentSize.height)
    }
    // Runs under the view's own appearance, so the colors follow light and dark.
    override func updateLayer() {
        layer?.backgroundColor = (pressed ? CagePalette.line : CagePalette.group).cgColor
        dot.backgroundColor = toneColor.cgColor
    }
    private var toneColor: NSColor {
        switch status.tone {
        case .busy: return CagePalette.accent
        case .ok: return CagePalette.success
        case .warn: return CagePalette.warn
        case .bad: return CagePalette.danger
        case .idle: return CagePalette.faint
        }
    }

    func update(_ next: VMacStatus) {
        guard next != status || label.stringValue.isEmpty else { return }
        status = next
        let text = NSMutableAttributedString(string: next.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: CagePalette.ink])
        if !next.detail.isEmpty {
            text.append(NSAttributedString(string: " · " + next.detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: CagePalette.muted]))
        }
        label.attributedStringValue = text
        setAccessibilityLabel("客机状态：\(next.title)，\(next.detail)")
        toolTip = "查看客机概览"
        // A slow breath marks work in progress.
        dot.removeAnimation(forKey: "breathe")
        if next.tone == .busy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1; breathe.toValue = 0.4; breathe.duration = 1.1
            breathe.autoreverses = true; breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(breathe, forKey: "breathe")
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false; needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The window's unified toolbar: the control center switch, the guest's
/// status, and the few guest actions that are always within reach.
final class VMacToolbarController: NSObject, NSToolbarDelegate {
    var onToggleControlCenter: (() -> Void)?
    var onShowOverview: (() -> Void)?
    var onUpload: (() -> Void)?
    var onFullScreen: (() -> Void)?
    var onRestart: (() -> Void)?
    var onStop: (() -> Void)?

    private let toolbar = NSToolbar(identifier: "VMacToolbar")
    private let pill = VMacStatusPill()
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var controlCenterActive = true
    private var guestActionsEnabled = false

    private static let toggle = NSToolbarItem.Identifier("vmac.controlCenter")
    private static let status = NSToolbarItem.Identifier("vmac.status")
    private static let upload = NSToolbarItem.Identifier("vmac.upload")
    private static let fullScreen = NSToolbarItem.Identifier("vmac.fullScreen")
    private static let more = NSToolbarItem.Identifier("vmac.more")

    func install(in window: NSWindow) {
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        pill.onClick = { [weak self] in self?.onShowOverview?() }
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }
    func update(_ status: VMacStatus) { pill.update(status) }
    func setControlCenterActive(_ active: Bool) {
        controlCenterActive = active
        refreshToggle()
    }
    func setGuestActionsEnabled(_ enabled: Bool) {
        guestActionsEnabled = enabled
        for identifier in [Self.upload, Self.more] { items[identifier]?.isEnabled = enabled }
    }

    private func symbol(_ name: String, _ description: String, tint: NSColor? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        guard let tint else { return image }
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
    }
    private func refreshToggle() {
        guard let item = items[Self.toggle] else { return }
        let label = controlCenterActive ? "回到桌面" : "控制中心"
        item.image = symbol("sidebar.left", label, tint: controlCenterActive ? CagePalette.accent : nil)
        item.label = label
        item.toolTip = controlCenterActive ? "回到客机桌面（⌃⌘,）" : "打开控制中心（⌃⌘,）"
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggle, .flexibleSpace, Self.status, .flexibleSpace, Self.upload, Self.fullScreen, Self.more]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch identifier {
        case Self.toggle:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.target = self; item.action = #selector(toggleControlCenter)
        case Self.status:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.view = pill
            item.label = "客机状态"
            item.visibilityPriority = .high
        case Self.upload:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.image = symbol("square.and.arrow.up", "传文件到客机")
            item.label = "传文件"; item.toolTip = "传文件到客机"
            item.target = self; item.action = #selector(upload)
            item.isEnabled = guestActionsEnabled
        case Self.fullScreen:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.image = symbol("arrow.up.left.and.arrow.down.right", "全屏")
            item.label = "全屏"; item.toolTip = "进入或退出全屏（⌃⌘F）"
            item.target = self; item.action = #selector(fullScreen)
        case Self.more:
            let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
            let menu = NSMenu()
            menu.addItem(withTitle: "重启客机", action: #selector(restart), keyEquivalent: "").target = self
            menu.addItem(withTitle: "停止客机", action: #selector(stop), keyEquivalent: "").target = self
            menuItem.menu = menu
            menuItem.showsIndicator = false
            menuItem.image = symbol("ellipsis.circle", "更多客机操作")
            menuItem.label = "更多"; menuItem.toolTip = "更多客机操作"
            menuItem.isEnabled = guestActionsEnabled
            item = menuItem
        default:
            return nil
        }
        item.isBordered = identifier != Self.status
        item.autovalidates = false
        items[identifier] = item
        if identifier == Self.toggle { refreshToggle() }
        return item
    }

    @objc private func toggleControlCenter() { onToggleControlCenter?() }
    @objc private func upload() { onUpload?() }
    @objc private func fullScreen() { onFullScreen?() }
    @objc private func restart() { onRestart?() }
    @objc private func stop() { onStop?() }
}
