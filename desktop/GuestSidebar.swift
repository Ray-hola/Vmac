import Cocoa

private func bounded(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

/// The sidebar's measures. Text comes in three sizes and starts on one edge;
/// icons, state dots and small labels share a column to its left. The divider
/// can drag the sidebar down to a rail of icons: on the way there the icons
/// travel to the middle and the labels fade, and below `railBelow` the brand,
/// the guest and the traffic take their compact forms.
private enum SidebarMetrics {
    /// From the sidebar's edge to a row.
    static let inset: CGFloat = 10
    /// From a row's edge to the icon column, and that column's width.
    static let iconLeading: CGFloat = 8, iconSlot: CGFloat = 20
    /// From a row's edge to where its label starts.
    static let textLeading: CGFloat = 34
    static let brand: CGFloat = 16, text: CGFloat = 14, small: CGFloat = 12
    static let railBelow: CGFloat = 146
    /// 0 while labels have room, 1 once only icons are left.
    static func rail(_ sidebarWidth: CGFloat) -> CGFloat { bounded((142 - sidebarWidth) / 58) }
    /// How much of a label still shows at this width.
    static func labels(_ sidebarWidth: CGFloat) -> CGFloat { bounded((sidebarWidth - 86) / 62) }
}

/// Shared timing for sidebar motion; honours the system Reduce Motion setting.
private enum SidebarMotion {
    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    /// The three steps every transition in VMac uses.
    static let fast: TimeInterval = 0.12, mid: TimeInterval = 0.2, slow: TimeInterval = 0.32
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func animate(_ duration: TimeInterval, _ changes: () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0 : duration
            context.timingFunction = ease
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }
    /// Backing layers only animate implicitly inside an animation context; free sublayers use the transaction.
    static func layers(_ duration: CFTimeInterval, _ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : duration
            context.timingFunction = ease
            context.allowsImplicitAnimation = true
            CATransaction.begin()
            CATransaction.setAnimationDuration(reduced ? 0 : duration)
            CATransaction.setAnimationTimingFunction(ease)
            changes()
            CATransaction.commit()
        }
    }
    static func fade(_ layer: CALayer?, _ duration: CFTimeInterval = mid) {
        guard let layer, !reduced else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        layer.add(transition, forKey: "fade")
    }
}

private final class GuestNavigationButton: NSButton {
    var selected = false { didSet { if selected != oldValue { updateStyle() } } }
    private var hover = false
    private var tracking: NSTrackingArea?
    private let iconView = NSImageView()
    private let labelView = NSTextField(labelWithString: "")
    private let fade = CAGradientLayer()
    private var symbol = ""
    private var symbolSize: CGFloat = 0
    override var isFlipped: Bool { true }

    func configure(label: String, symbol: String) {
        title = ""; image = nil; self.symbol = symbol
        toolTip = label
        labelView.stringValue = label
        labelView.lineBreakMode = .byTruncatingTail
        labelView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelView.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView); addSubview(labelView)
        updateStyle()
    }
    override func layout() {
        super.layout()
        let sidebarWidth = bounds.width + SidebarMetrics.inset * 2
        let rail = SidebarMetrics.rail(sidebarWidth)
        // The icon is a little smaller than the text beside it, and grows once it is the whole row.
        let size = SidebarMetrics.text - 0.5 + rail * 3.5
        if size != symbolSize {
            symbolSize = size
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        }
        let slot = SidebarMetrics.iconSlot + rail * 4
        let leading = SidebarMetrics.iconLeading
        let x = leading + (bounds.midX - slot / 2 - leading) * rail
        iconView.frame = NSRect(x: x, y: (bounds.height - slot) / 2, width: slot, height: slot)
        let opacity = SidebarMetrics.labels(sidebarWidth)
        let labelX = max(SidebarMetrics.textLeading, iconView.frame.maxX + 6)
        let labelHeight = ceil(labelView.intrinsicContentSize.height)
        labelView.frame = NSRect(x: labelX, y: (bounds.height - labelHeight) / 2, width: max(0, bounds.width - labelX - 8), height: labelHeight)
        // Without room for even one character the label is left out.
        labelView.alphaValue = opacity
        labelView.isHidden = opacity == 0 || labelView.frame.width < SidebarMetrics.text * 2
        // A label too long for its row fades out at the right edge.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = labelView.bounds
        let overflow = labelView.intrinsicContentSize.width > labelView.bounds.width
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, (overflow ? NSColor.clear : NSColor.black).cgColor]
        fade.locations = [0, NSNumber(value: Double(max(0, 1 - 10 / max(1, labelView.bounds.width)))), 1]
        labelView.layer?.mask = fade
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true; updateStyle() }
    override func mouseExited(with event: NSEvent) { hover = false; updateStyle() }
    private func updateStyle() {
        // The current page is said in blue over the pale blue fill that
        // slides to it; the row under the pointer takes a faint fill.
        let color = selected ? CagePalette.accentText : CagePalette.ink
        iconView.contentTintColor = color; labelView.textColor = color
        labelView.font = .systemFont(ofSize: SidebarMetrics.text, weight: selected ? .medium : .regular)
        layer?.cornerRadius = 10
        layer?.backgroundColor = (hover && !selected ? CagePalette.hover : NSColor.clear).cgColor
        setAccessibilityValue(selected ? "已选择" : "")
        needsLayout = true
    }
}

/// Start when stopped, restart when running, spinner while a job runs.
private final class SidebarPowerButton: NSButton {
    enum Mode: Equatable { case start, restart, busy }
    private(set) var mode: Mode = .start
    private let disc = CALayer()
    private let glyph = CALayer()
    private let spinner = CAShapeLayer()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""; isBordered = false; bezelStyle = .inline; focusRingType = .default
        wantsLayer = true
        layer?.addSublayer(disc)
        disc.addSublayer(glyph)
        disc.addSublayer(spinner)
        spinner.fillColor = NSColor.clear.cgColor
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.7
        apply(.start, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = side / 2
        let glyphSide = round(side * 0.42)
        glyph.frame = CGRect(x: (side-glyphSide)/2, y: (side-glyphSide)/2, width: glyphSide, height: glyphSide)
        let ring = CGRect(x: side*0.3, y: side*0.3, width: side*0.4, height: side*0.4)
        spinner.frame = disc.bounds
        spinner.path = CGPath(ellipseIn: ring, transform: nil)
        CATransaction.commit()
        refreshGlyph()
    }
    func apply(_ next: Mode, animated: Bool = true) {
        if animated && next != mode { SidebarMotion.fade(disc) }
        mode = next
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let filled = next == .start && isEnabled
        disc.backgroundColor = (filled ? CagePalette.accent : CagePalette.card).cgColor
        disc.borderColor = CagePalette.line.cgColor
        spinner.strokeColor = CagePalette.accent.cgColor
        disc.borderWidth = filled ? 0 : 1
        spinner.isHidden = next != .busy
        glyph.isHidden = next == .busy
        CATransaction.commit()
        if next == .busy, spinner.animation(forKey: "spin") == nil, !SidebarMotion.reduced {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -Double.pi * 2
            spin.duration = 0.9; spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        } else if next != .busy { spinner.removeAnimation(forKey: "spin") }
        let label = next == .start ? "启动客机" : next == .restart ? "重启客机" : "正在处理"
        toolTip = label; setAccessibilityLabel(label)
        refreshGlyph()
    }
    override var isEnabled: Bool { didSet { apply(mode, animated: false); alphaValue = isEnabled || mode == .busy ? 1 : 0.55 } }
    private func refreshGlyph() {
        let symbol = mode == .start ? "play.fill" : "arrow.clockwise"
        let tint = mode == .start && isEnabled ? NSColor.white : CagePalette.ink
        let size = glyph.bounds.width
        guard size > 0, let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .semibold)) else { return }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let fitted = base.size.width > 0 ? min(rect.width / base.size.width, rect.height / base.size.height) : 1
            let drawn = NSSize(width: base.size.width * fitted, height: base.size.height * fitted)
            let target = NSRect(x: (rect.width - drawn.width) / 2 + (symbol == "play.fill" ? 1 : 0), y: (rect.height - drawn.height) / 2, width: drawn.width, height: drawn.height)
            base.draw(in: target)
            tint.set(); target.fill(using: .sourceAtop)
            return true
        }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.contentsScale = scale
        glyph.contents = image.layerContents(forContentsScale: scale)
        glyph.contentsGravity = .resizeAspect
        CATransaction.commit()
    }
    override func highlight(_ flag: Bool) {
        SidebarMotion.layers(SidebarMotion.fast) { disc.setAffineTransform(flag ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity) }
    }
}

/// The current guest's name, state and its single lifecycle control. It is the
/// one raised surface in the sidebar, like the first action in DeepSeek's.
private final class SidebarMachineCard: NSView {
    var onOpen: (() -> Void)?
    let power = SidebarPowerButton(frame: .zero)
    /// The white surface; a layer of its own, so its shadow is not AppKit's to reset.
    private let surface = CALayer()
    private let dot = CALayer()
    private let halo = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "已停止")
    private var hover = false
    private var tracking: NSTrackingArea?
    /// In the rail only the power control is left.
    private var compact = false
    /// A guest at rest is a pale dot; one on its way is blue, one that is ready green.
    private var dotColor = CagePalette.caption
    override var isFlipped: Bool { true }
    init(profile: String) {
        super.init(frame: .zero)
        wantsLayer = true
        name.stringValue = profile
        surface.cornerRadius = 14
        surface.shadowColor = NSColor(srgbRed: 72 / 255, green: 104 / 255, blue: 178 / 255, alpha: 1).cgColor
        layer?.addSublayer(surface)
        name.font = .systemFont(ofSize: SidebarMetrics.text, weight: .medium); name.textColor = CagePalette.ink
        state.font = .systemFont(ofSize: SidebarMetrics.small); state.textColor = CagePalette.secondary
        for label in [name, state] { label.lineBreakMode = .byTruncatingTail; label.cell?.usesSingleLineMode = true; label.wantsLayer = true; addSubview(label) }
        layer?.addSublayer(halo); layer?.addSublayer(dot)
        dot.cornerRadius = 4; halo.cornerRadius = 8
        addSubview(power)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(profile)
        refreshChrome()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        compact = bounds.width < SidebarMetrics.railBelow - SidebarMetrics.inset * 2
        name.isHidden = compact; state.isHidden = compact; dot.isHidden = compact; halo.isHidden = compact
        let side: CGFloat = compact ? 38 : 28
        power.frame = compact ? NSRect(x: (bounds.width-side)/2, y: (bounds.height-side)/2, width: side, height: side)
            : NSRect(x: bounds.width-side-8, y: (bounds.height-side)/2, width: side, height: side)
        let textX = SidebarMetrics.textLeading, textWidth = max(0, power.frame.minX - textX - 2)
        name.frame = NSRect(x: textX, y: 9, width: textWidth, height: 20)
        state.frame = NSRect(x: textX, y: 30, width: textWidth, height: 17)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.frame = bounds
        // The dot sits in the icon column, level with the name.
        dot.frame = CGRect(x: SidebarMetrics.iconLeading + SidebarMetrics.iconSlot / 2 - 4, y: 15, width: 8, height: 8)
        halo.frame = dot.frame.insetBy(dx: -4, dy: -4)
        CATransaction.commit()
        refreshChrome()
    }
    func update(running: Bool, ready: Bool, busy: Bool, setup: Bool, activity: String) {
        // A ready guest turns the card into the way back to its desktop.
        let returning = ready && !busy && !setup
        let text = setup ? "等待安装" : busy ? (["start": "正在启动…", "restart": "正在重启…", "stop": "正在停止…"][activity] ?? "正在处理…")
            : ready ? "回到桌面" : running ? "运行中 · 连接中" : "已停止"
        if state.stringValue != text { SidebarMotion.fade(state.layer); state.stringValue = text }
        state.textColor = returning ? CagePalette.accentText : CagePalette.secondary
        state.font = .systemFont(ofSize: SidebarMetrics.small, weight: returning ? .medium : .regular)
        // Green once the desktop is ready, blue while it is on its way there.
        dotColor = setup || !(busy || running) ? CagePalette.caption : returning ? CagePalette.ok : CagePalette.accent
        refreshDot()
        let pulsing = (busy || (running && !ready)) && !setup
        if pulsing, halo.animation(forKey: "pulse") == nil, !SidebarMotion.reduced {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0; pulse.toValue = 1; pulse.autoreverses = true
            pulse.duration = 0.7; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(pulse, forKey: "pulse")
        } else if !pulsing { halo.removeAnimation(forKey: "pulse") }
        halo.opacity = pulsing ? 1 : 0
        power.apply(busy ? .busy : running ? .restart : .start)
        power.isEnabled = !setup && !busy
        setAccessibilityValue(text)
        toolTip = "\(name.stringValue)：\(text)"
    }
    private func refreshDot() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.backgroundColor = dotColor.cgColor
        halo.backgroundColor = CagePalette.accentSoft.cgColor
        CATransaction.commit()
    }
    private func refreshChrome() {
        // White with a soft shadow that deepens under the pointer; in the
        // rail the power control stands alone.
        SidebarMotion.layers(SidebarMotion.fast) {
            surface.backgroundColor = (compact ? NSColor.clear : CagePalette.card).cgColor
            surface.shadowOpacity = compact ? 0 : hover ? 0.2 : 0.12
            surface.shadowRadius = hover ? 6 : 2.5
            surface.shadowOffset = CGSize(width: 0, height: hover ? 3 : 1)
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true; refreshChrome() }
    override func mouseExited(with event: NSEvent) { hover = false; refreshChrome() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
}

/// A status lamp that also navigates to the page explaining it.
private final class SidebarLamp: NSButton {
    var color = CagePalette.caption
    /// Without room for its name a lamp is the dot alone.
    var showsLabel = true { didSet { if showsLabel != oldValue { needsDisplay = true } } }
    private var hover = false
    private var tracking: NSTrackingArea?
    private let name: String
    private static let dot: CGFloat = 7, gap: CGFloat = 5
    override var isFlipped: Bool { true }
    init(_ name: String) {
        self.name = name
        super.init(frame: .zero)
        title = ""; isBordered = false; bezelStyle = .inline
        wantsLayer = true
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var label: NSAttributedString {
        NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: SidebarMetrics.small), .foregroundColor: hover ? CagePalette.ink : CagePalette.secondary])
    }
    /// The dot and the name, side by side.
    var naturalWidth: CGFloat { Self.dot + Self.gap + ceil(label.size().width) }
    func update(_ detail: String, _ state: Int) {
        // Green when well, blue when working, red when failed, pale when at rest.
        color = state == 1 ? CagePalette.ok : state == 2 ? CagePalette.accent : state == 4 ? CagePalette.danger : CagePalette.caption
        toolTip = "\(name)：\(detail)"; setAccessibilityValue(detail); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let x = showsLabel ? 0 : (bounds.width - Self.dot) / 2
        let rect = NSRect(x: x, y: bounds.midY - Self.dot / 2, width: Self.dot, height: Self.dot)
        color.setFill(); NSBezierPath(ovalIn: rect).fill()
        guard showsLabel else { return }
        let label = label
        label.draw(at: NSPoint(x: rect.maxX + Self.gap, y: bounds.midY - label.size().height / 2))
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
}

/// One direction of traffic in the rail: an arrow, the figure and its unit in a ring.
private final class SidebarSpeedCircle: NSView {
    var upload = true { didSet { updateLabels() } }
    var value: Double? { didSet { updateLabels() } }
    private let arrow = NSTextField(labelWithString: "")
    private let speed = NSTextField(labelWithString: "")
    private let unit = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (label, size, color) in [(arrow, SidebarMetrics.small, CagePalette.accent),
                                     (speed, SidebarMetrics.small, CagePalette.ink), (unit, SidebarMetrics.small, CagePalette.secondary)] {
            label.alignment = .center
            label.font = CagePalette.mono(size, weight: label === speed ? .medium : .regular)
            label.textColor = color
            label.cell?.usesSingleLineMode = true
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        updateLabels()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        for (label, y) in [(arrow, CGFloat(4)), (speed, 18), (unit, 34)] {
            label.frame = NSRect(x: 1, y: y, width: max(0, bounds.width - 2), height: 16)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        CagePalette.card.setFill(); CagePalette.line.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1
        ring.fill(); ring.stroke()
    }
    private func updateLabels() {
        let parts = speedParts(value)
        arrow.stringValue = upload ? "↑" : "↓"
        speed.stringValue = parts.0
        unit.stringValue = parts.1
    }
}

private func speedParts(_ value: Double?) -> (String,String) {
    guard let value, value.isFinite, value >= 0 else { return ("—","B/s") }
    if value >= 1024*1024 { return (String(format: value >= 100*1024*1024 ? "%.0f" : "%.1f",value/1024/1024),"MB/s") }
    if value >= 1024 { return (String(format: value >= 100*1024 ? "%.0f" : "%.1f",value/1024),"KB/s") }
    return (String(format:"%.0f",value),"B/s")
}
private func byteText(_ value: Double) -> String {
    if value >= 1024*1024*1024 { return String(format:"%.2f GB",value/1024/1024/1024) }
    if value >= 1024*1024 { return String(format:"%.1f MB",value/1024/1024) }
    if value >= 1024 { return String(format:"%.1f KB",value/1024) }
    return String(format:"%.0f B",value)
}

/// Traffic through the proxy, what is left of the quota, and three lamps.
/// Each figure is a row like the ones on the pages: its name in the label
/// grey on the left, its value on the right.
private final class SidebarTelemetry: NSView {
    /// What there is room for: everything, the lamps alone, or nothing.
    enum Form { case full, lamps, hidden }
    var form = Form.full { didSet { if form != oldValue { needsLayout = true; needsDisplay = true } } }
    static func height(width: CGFloat, form: Form) -> CGFloat {
        let rail = width < SidebarMetrics.railBelow
        switch form {
        case .full: return rail ? 156 : rowHeight * 4 + 46
        case .lamps: return rail ? 18 : 24
        case .hidden: return 0
        }
    }
    private static let rowHeight: CGFloat = 22
    var onSelect: ((String) -> Void)?
    private var figures = [("上传", "—"), ("下载", "—"), ("已用", "—"), ("余量", "—")]
    private var usedPercent: Double?
    private var compactQuota = "—%"
    private let circles = [SidebarSpeedCircle(), SidebarSpeedCircle()]
    private let lamps = [SidebarLamp("代理"),SidebarLamp("环境"),SidebarLamp("虚拟机")]
    private let destinations = ["proxy", "checks", "overview"]
    private let track = CALayer()
    private let fill = CALayer()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("代理流量")
        circles[0].upload = true; circles[1].upload = false
        for circle in circles { circle.setAccessibilityElement(true); circle.setAccessibilityRole(.image); addSubview(circle) }
        for (lamp, destination) in zip(lamps, destinations) {
            lamp.target = self; lamp.action = #selector(lampPressed(_:))
            lamp.identifier = NSUserInterfaceItemIdentifier(destination)
            addSubview(lamp)
        }
        // What is left of the quota: a blue bar in a soft track, shown when the subscription states one.
        track.backgroundColor = CagePalette.track.cgColor
        track.cornerRadius = 2; fill.cornerRadius = 2
        fill.anchorPoint = .zero
        layer?.addSublayer(track); layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func lampPressed(_ sender: NSButton) { if let id = sender.identifier?.rawValue { onSelect?(id) } }
    func updateStatus(running: Bool,ready: Bool,busy: Bool,network: String,failed: Bool) {
        lamps[1].update(failed ? "检查失败" : busy ? "正在检查" : ready ? "已就绪" : "未就绪",failed ? 4 : busy ? 2 : ready ? 1 : 0)
        lamps[2].update(running ? "运行中" : "已停止",running ? 1 : 0)
        // Proxy health is updated independently by the aggregate counter sampler.
        networkLabel=network;environmentBusy=busy;refreshProxyLamp()
    }
    private var networkLabel="等待检测"
    private var proxyAvailable=false
    private var environmentBusy=false
    private func refreshProxyLamp() {
        let open=networkLabel == "外网已放行"
        lamps[0].update(proxyAvailable ? networkLabel : "核心未连接",proxyAvailable ? (open ? 1 : 2) : (environmentBusy ? 2 : 0))
    }
    func updateTraffic(_ data:[String:Any]) {
        proxyAvailable=data["available"] as? Bool ?? false;refreshProxyLamp()
        let u=(data["upload_rate"] as? NSNumber)?.doubleValue,d=(data["download_rate"] as? NSNumber)?.doubleValue
        let us=speedParts(u),ds=speedParts(d)
        figures[0].1 = "\(us.0) \(us.1)"; figures[1].1 = "\(ds.0) \(ds.1)"
        circles[0].value = u; circles[1].value = d
        for (circle, text) in zip(circles, ["上传：\(us.0) \(us.1)", "下载：\(ds.0) \(ds.1)"]) { circle.toolTip = text; circle.setAccessibilityLabel(text) }
        let uploaded=(data["upload_24h"] as? NSNumber)?.doubleValue ?? 0,downloaded=(data["download_24h"] as? NSNumber)?.doubleValue ?? 0
        let quota=data["quota"] as? [String:Any]
        usedPercent=(quota?["used_percent"] as? NSNumber)?.doubleValue
        compactQuota = usedPercent.map { String(format: "%.0f%%", $0) } ?? "—%"
        if let used=(quota?["used"] as? NSNumber)?.doubleValue,let cap=(quota?["total"] as? NSNumber)?.doubleValue,let remaining=(quota?["remaining"] as? NSNumber)?.doubleValue {
            figures[2] = ("已用", byteText(used))
            figures[3] = ("余量", byteText(remaining))
            toolTip="订阅已用 \(byteText(used)) / \(byteText(cap))\n订阅更新：\(quota?["updated_at"] as? String ?? "未知")\n本地近24小时：↑ \(byteText(uploaded)) · ↓ \(byteText(downloaded))"
        } else {
            figures[2] = ("流量", byteText(uploaded+downloaded))
            figures[3] = ("余量", "未提供额度")
            toolTip="订阅未提供额度，余量和已用比例未知。\n流量为本机记录的近24小时累计。"
        }
        setAccessibilityValue(figures.map { "\($0.0) \($0.1)" }.joined(separator: "；") + "；\(compactQuota) 已用")
        layoutQuota(animated: true)
        needsDisplay=true
    }
    /// Where a group title's text starts in the icon column (a label draws 2
    /// points inside its frame), and the mirror of that edge on the right.
    private var edges: (left: CGFloat, right: CGFloat) {
        let left = SidebarMetrics.inset + SidebarMetrics.iconLeading + 2
        return (left, bounds.width - left)
    }
    private var rail: Bool { bounds.width < SidebarMetrics.railBelow }
    private func layoutQuota(animated: Bool) {
        let bar = CGRect(x: edges.left, y: Self.rowHeight * 4 + 6, width: max(0, edges.right - edges.left), height: 4)
        let remaining = usedPercent.map { CGFloat(max(0, min(1, 1 - $0 / 100))) } ?? 0
        let apply = {
            self.track.frame = bar
            self.fill.bounds = CGRect(x: 0, y: 0, width: bar.width * remaining, height: bar.height)
            self.fill.position = bar.origin
            // Nearly used up: the bar turns amber, and the figures beside it say so.
            self.fill.backgroundColor = ((self.usedPercent ?? 0) > 85 ? CagePalette.warn : CagePalette.accent).cgColor
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.isHidden = rail || form != .full || usedPercent == nil; fill.isHidden = track.isHidden
        CATransaction.commit()
        if animated { SidebarMotion.layers(SidebarMotion.slow, apply) }
        else { CATransaction.begin(); CATransaction.setDisableActions(true); apply(); CATransaction.commit() }
    }
    override func layout() {
        super.layout()
        circles.forEach { $0.isHidden = !rail || form != .full }
        lamps.forEach { $0.isHidden = form == .hidden }
        if rail {
            let diameter: CGFloat = 52
            circles[0].frame = NSRect(x: (bounds.width - diameter) / 2, y: 0, width: diameter, height: diameter)
            circles[1].frame = NSRect(x: (bounds.width - diameter) / 2, y: 58, width: diameter, height: diameter)
            for (i, lamp) in lamps.enumerated() {
                lamp.showsLabel = false
                lamp.frame = NSRect(x: bounds.midX - 27 + CGFloat(i) * 18, y: bounds.height - 18, width: 18, height: 18)
            }
        } else {
            // Each lamp takes the room of its name and they spread across the
            // width; without room for the names they are three dots.
            let widths = lamps.map(\.naturalWidth), content = edges.right - edges.left
            let named = widths.reduce(0, +) + 12 <= content
            let gap = named ? (content - widths.reduce(0, +)) / 2 : 0
            var x = edges.left
            for (i, lamp) in lamps.enumerated() {
                lamp.showsLabel = named
                let width = named ? widths[i] : content / 3
                lamp.frame = NSRect(x: x, y: bounds.height - 24, width: width, height: 24)
                x += width + gap
            }
        }
        layoutQuota(animated: false)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard form == .full else { return }
        if rail {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            ("\(compactQuota)已用" as NSString).draw(in: NSRect(x: 2, y: 115, width: bounds.width - 4, height: 16), withAttributes: [
                .font: CagePalette.mono(SidebarMetrics.small), .foregroundColor: CagePalette.secondary, .paragraphStyle: style])
            return
        }
        for (i, (name, value)) in figures.enumerated() {
            let row = NSRect(x: edges.left, y: CGFloat(i) * Self.rowHeight, width: edges.right - edges.left, height: Self.rowHeight)
            let label = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: SidebarMetrics.small), .foregroundColor: CagePalette.tertiary])
            let figure = NSAttributedString(string: value, attributes: [.font: CagePalette.mono(SidebarMetrics.small, weight: .medium), .foregroundColor: CagePalette.ink])
            label.draw(at: NSPoint(x: row.minX, y: row.midY - label.size().height / 2))
            figure.draw(at: NSPoint(x: max(row.minX + label.size().width + 8, row.maxX - figure.size().width), y: row.midY - figure.size().height / 2))
        }
    }
}

func activeProfileName() -> String {
    let id = CageProfile.activeProfile
    // The default guest is listed as "原有 macOS 客机"; the short form fits the sidebar card.
    if id == CageProfile.defaultProfile { return "macOS 客机" }
    return CageProfile.savedProfiles[id] ?? "macOS 客机"
}

final class CageGuestSidebar: NSView {
    var onSelect:((String)->Void)?
    // The pages, in the order and groups of ui/src/vmac-pages.mjs (kept in
    // step by ui/src/vmac-pages-sync.test.mjs): id, title, symbol, group.
    // sidebar-pages:begin
    private let pageRows: [(String, String, String, String)] = [
        ("overview", "概览", "rectangle.grid.2x2", ""),
        ("machines", "虚拟机与磁盘", "internaldrive", "这台客机"),
        ("system", "账户与系统", "person.crop.circle", "这台客机"),
        ("sharing", "共享与传输", "arrow.left.arrow.right", "这台客机"),
        ("proxy", "代理线路", "network", "网络"),
        ("checks", "环境检测", "checkmark.shield", "网络"),
        ("general", "通用", "gearshape", "VMac"),
        ("security", "账户与安全", "lock.shield", "VMac"),
        ("recovery", "环境与恢复", "arrow.counterclockwise", "VMac"),
        ("about", "关于", "info.circle", "VMac"),
    ]
    // sidebar-pages:end
    private var rows:[String:GuestNavigationButton]=[:]
    /// Group titles, keyed by the id of the first page under each, and the
    /// short rule that stands in for a title in the rail.
    private var headers:[String:NSTextField]=[:]
    private var rules:[String:CALayer]=[:]
    private let brand=NSTextField(labelWithString:"VMac")
    private let logo=NSImageView()
    private let machine = SidebarMachineCard(profile: activeProfileName())
    private let pill = NSView()
    private var selected = "overview"
    private var pillAnimating = false
    private let telemetry=SidebarTelemetry(frame:.zero)
    override var isFlipped: Bool { true }
    init() {
        super.init(frame:.zero)
        wantsLayer=true
        layer?.backgroundColor = CagePalette.sidebar.cgColor
        translatesAutoresizingMaskIntoConstraints=false
        brand.font = .systemFont(ofSize: SidebarMetrics.brand, weight: .semibold);brand.textColor=CagePalette.ink;brand.lineBreakMode = .byTruncatingTail;brand.cell?.usesSingleLineMode=true;addSubview(brand)
        if let path=Bundle.main.path(forResource:"VMacMark",ofType:"pdf") { logo.image=NSImage(contentsOfFile:path) }
        logo.imageScaling = .scaleProportionallyUpOrDown;logo.setAccessibilityElement(false);addSubview(logo)
        machine.onOpen = { [weak self] in self?.onSelect?("desktop") }
        machine.power.target = self; machine.power.action = #selector(powerPressed)
        addSubview(machine)
        // The current page sits on a pale blue fill that slides to it.
        pill.wantsLayer = true
        pill.layer?.backgroundColor = CagePalette.accentSoft.cgColor
        pill.layer?.cornerRadius = 10
        addSubview(pill)
        var group = ""
        for (id,label,symbol,section) in pageRows {
            if section != group, !section.isEmpty {
                let header = NSTextField(labelWithString: section)
                header.font = .systemFont(ofSize: SidebarMetrics.small, weight: .medium)
                header.textColor = CagePalette.tertiary
                header.setAccessibilityRole(.staticText)
                addSubview(header); headers[id] = header
                let rule = CALayer()
                rule.backgroundColor = CagePalette.line.cgColor
                layer?.addSublayer(rule); rules[id] = rule
            }
            group = section
            let button=GuestNavigationButton(title:label,target:self,action:#selector(selectRow(_:)))
            button.identifier=NSUserInterfaceItemIdentifier(id)
            button.configure(label: label, symbol: symbol)
            button.isBordered=false;button.bezelStyle = .inline;button.focusRingType = .default
            button.wantsLayer=true;button.setAccessibilityLabel(label)
            addSubview(button);rows[id]=button
        }
        telemetry.onSelect = { [weak self] id in self?.onSelect?(id) }
        addSubview(telemetry)
        select("overview")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let width = bounds.width, inset = SidebarMetrics.inset
        let railed = width < SidebarMetrics.railBelow, rail = SidebarMetrics.rail(width)
        brand.isHidden = railed
        // The mark is centred on the icon column, the name starts on the text edge.
        logo.frame = railed ? NSRect(x: (width - 30) / 2, y: 14, width: 30, height: 30)
            : NSRect(x: inset + SidebarMetrics.iconLeading - 2, y: 16, width: 24, height: 24)
        brand.frame = NSRect(x: inset + SidebarMetrics.textLeading, y: 17, width: max(0, width - inset * 2 - SidebarMetrics.textLeading), height: 22)
        machine.frame = NSRect(x: inset, y: 56, width: max(0, width - inset * 2), height: railed ? 46 : 56)
        let top = machine.frame.maxY + 12, bottom: CGFloat = 12, gap: CGFloat = 2
        // A group opens with its title; in the rail the title gives way to a short rule.
        let rowPreferred: CGFloat = 36, rowMinimum: CGFloat = 30
        let headPreferred = 34 - 16 * rail, headMinimum = 26 - 10 * rail
        func needed(_ row: CGFloat, _ head: CGFloat) -> CGFloat {
            CGFloat(pageRows.count) * (row + gap) + CGFloat(headers.count) * head
        }
        func room(_ form: SidebarTelemetry.Form) -> CGFloat {
            bounds.height - top - bottom - (form == .hidden ? 0 : SidebarTelemetry.height(width: width, form: form) + 12)
        }
        // In a short window the traffic figures give way first, then the
        // lamps; only after that is a row squeezed below its smallest height.
        let least = needed(rowMinimum, headMinimum)
        let form = [SidebarTelemetry.Form.full, .lamps].first { room($0) >= least } ?? .hidden
        let available = room(form)
        let stretch = bounded((available - least) / (needed(rowPreferred, headPreferred) - least))
        let squeeze = min(1, max(0, available) / least)
        let rowHeight = (rowMinimum + (rowPreferred - rowMinimum) * stretch) * squeeze
        let headHeight = (headMinimum + (headPreferred - headMinimum) * stretch) * squeeze
        telemetry.form = form
        telemetry.isHidden = form == .hidden
        let telemetryHeight = SidebarTelemetry.height(width: width, form: form)
        telemetry.frame = NSRect(x: 0, y: bounds.height - bottom - telemetryHeight, width: width, height: telemetryHeight)
        telemetry.needsLayout = true
        // A title is gone by the time the rule that stands in for it shows.
        let titles = bounded((width - 126) / 20), ruled = bounded((126 - width) / 20)
        var y = top
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, _, _, _) in pageRows {
            if let header = headers[id] {
                let height = floor(headHeight)
                header.frame = NSRect(x: inset + SidebarMetrics.iconLeading, y: y + height - 22, width: max(0, width - (inset + SidebarMetrics.iconLeading) * 2), height: 16)
                header.alphaValue = titles; header.isHidden = titles == 0
                rules[id]?.frame = CGRect(x: (width - 16) / 2, y: y + floor(height / 2) - 1, width: 16, height: 1)
                rules[id]?.opacity = Float(ruled)
                y += height
            }
            let height = floor(rowHeight + gap)
            rows[id]?.frame = NSRect(x: inset, y: y, width: max(0, width - inset * 2), height: max(0, height - gap))
            rows[id]?.needsLayout = true
            y += height
        }
        CATransaction.commit()
        if !pillAnimating { pill.frame = pillTarget() }
    }
    private func pillTarget() -> NSRect {
        rows[selected]?.frame ?? .zero
    }
    @objc private func selectRow(_ sender:NSButton) { if let id=sender.identifier?.rawValue { onSelect?(id) } }
    @objc private func powerPressed() { onSelect?(machine.power.mode == .restart ? "restart" : "start") }
    /// Names from before the pages were merged still select the overview.
    func select(_ requested:String) {
        let id = requested == "lifecycle" || requested == "desktop" ? "overview" : requested
        guard rows[id] != nil else { return }
        let changed = id != selected
        selected = id
        for (key,button) in rows { button.selected = key == selected }
        guard changed else { return }
        guard window != nil, !pill.frame.isEmpty else { pill.frame = pillTarget(); return }
        pillAnimating = true
        SidebarMotion.animate(SidebarMotion.mid, { pill.animator().frame = pillTarget() }, completion: { [weak self] in
            guard let self else { return }
            self.pillAnimating = false
            self.pill.frame = self.pillTarget()
        })
    }
    func update(running:Bool,ready:Bool,busy:Bool,networkLabel:String,failed:Bool=false,setup:Bool=false,activity:String="") {
        machine.update(running: running, ready: ready, busy: busy, setup: setup, activity: activity)
        telemetry.updateStatus(running:running,ready:ready,busy:busy,network:networkLabel,failed:failed)
    }
    func updateTraffic(_ data:[String:Any]) { telemetry.updateTraffic(data) }
}
