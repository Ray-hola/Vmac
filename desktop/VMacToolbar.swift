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
        toolTip = "查看客机状态"
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

/// What the status pill opens: three facts about the guest, and the pages
/// that say more about each.
final class VMacStatusPopover: NSViewController {
    var onNavigate: ((String) -> Void)?
    private var detail = VMacStatusDetail(body: [:])
    private let values = (0..<3).map { _ in NSTextField(labelWithString: "—") }
    private static let rows = ["网络保护", "出口", "磁盘"]
    private static let pages = [("概览", "overview"), ("代理线路", "proxy"), ("环境检测", "checks")]

    override func loadView() {
        let grid = NSGridView(views: zip(Self.rows, values).map { title, value in
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12); label.textColor = CagePalette.muted
            value.font = .systemFont(ofSize: 12, weight: .medium); value.textColor = CagePalette.ink
            value.alignment = .right; value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [label, value]
        })
        grid.rowSpacing = 9; grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        let line = NSBox(); line.boxType = .separator
        let buttons = NSStackView(views: Self.pages.enumerated().map { index, page in
            let button = NSButton(title: page.0, target: self, action: #selector(open(_:)))
            button.bezelStyle = .rounded; button.controlSize = .small; button.tag = index
            return button
        })
        buttons.distribution = .fillEqually; buttons.spacing = 8
        let stack = NSStackView(views: [grid, line, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        var constraints = [stack.widthAnchor.constraint(equalToConstant: 320)]
        for part in [grid, line, buttons] as [NSView] {
            constraints.append(part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32))
        }
        NSLayoutConstraint.activate(constraints)
        view = stack
        apply()
    }
    func update(_ next: VMacStatusDetail) {
        guard next != detail else { return }
        detail = next
        if isViewLoaded { apply() }
    }
    private func apply() {
        for (field, text) in zip(values, [detail.network, detail.exit, detail.disk]) {
            field.stringValue = text
            // A long exit is cut in the middle; the full text stays one hover away.
            field.toolTip = text
        }
    }
    @objc private func open(_ sender: NSButton) { onNavigate?(Self.pages[sender.tag].1) }
}

/// The window's unified toolbar: the control center switch, the guest's
/// status, and the few guest actions that are always within reach.
final class VMacToolbarController: NSObject, NSToolbarDelegate, NSPopoverDelegate {
    var onToggleControlCenter: (() -> Void)?
    var onNavigate: ((String) -> Void)?
    var onUpload: (() -> Void)?
    var onFullScreen: (() -> Void)?
    var onRestart: (() -> Void)?
    var onStop: (() -> Void)?

    private let toolbar = NSToolbar(identifier: "VMacToolbar")
    private let pill = VMacStatusPill()
    private let popover = NSPopover()
    private let statusPopover = VMacStatusPopover()
    private var popoverClosedAt: TimeInterval = 0
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var controlCenterActive = true
    private var guestActions = VMacGuestActions(running: false, ready: false)

    private static let toggle = NSToolbarItem.Identifier("vmac.controlCenter")
    private static let status = NSToolbarItem.Identifier("vmac.status")
    private static let upload = NSToolbarItem.Identifier("vmac.upload")
    private static let fullScreen = NSToolbarItem.Identifier("vmac.fullScreen")
    private static let more = NSToolbarItem.Identifier("vmac.more")

    func install(in window: NSWindow) {
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        pill.onClick = { [weak self] in self?.toggleStatusPopover() }
        popover.contentViewController = statusPopover
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.delegate = self
        statusPopover.onNavigate = { [weak self] destination in
            self?.popover.performClose(nil)
            self?.onNavigate?(destination)
        }
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }
    func update(_ status: VMacStatus) { pill.update(status) }
    func update(detail: VMacStatusDetail) { statusPopover.update(detail) }
    func setControlCenterActive(_ active: Bool) {
        controlCenterActive = active
        refreshToggle()
    }
    func setGuestActions(_ actions: VMacGuestActions) {
        guestActions = actions
        items[Self.upload]?.isEnabled = actions.upload
        items[Self.more]?.isEnabled = actions.lifecycle
    }

    private func toggleStatusPopover() {
        // The click that dismisses the open popover also reaches the pill; it
        // must not open the popover again.
        guard !popover.isShown, ProcessInfo.processInfo.systemUptime - popoverClosedAt > 0.3 else {
            popover.performClose(nil)
            return
        }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: pill.bounds, of: pill, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { popoverClosedAt = ProcessInfo.processInfo.systemUptime }

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
            item.isEnabled = guestActions.upload
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
            menuItem.isEnabled = guestActions.lifecycle
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
