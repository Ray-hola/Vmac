import Cocoa

private func bounded(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

private extension NSView {
    /// Layer colors are fixed once set, so they are resolved under this view's
    /// own appearance and set again whenever that appearance changes.
    func resolvingColors(_ body: () -> Void) { effectiveAppearance.performAsCurrentDrawingAppearance(body) }
}

/// Shared timing for sidebar motion; honours the system Reduce Motion setting.
private enum SidebarMotion {
    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
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
    static func fade(_ layer: CALayer?, _ duration: CFTimeInterval = 0.18) {
        guard let layer, !reduced else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        layer.add(transition, forKey: "fade")
    }
}

private final class GuestNavigationButton: NSButton {
    var selected = false { didSet { if selected != oldValue { updateStyle() } } }
    var expanded: Bool? {
        didSet {
            if let expanded { setAccessibilityExpanded(expanded) }
            needsLayout = true
        }
    }
    private var hover = false
    private var tracking: NSTrackingArea?
    private let iconView = NSImageView()
    private let labelView = NSTextField(labelWithString: "")
    private let disclosure = NSImageView()
    private let fade = CAGradientLayer()
    private var symbol = ""
    private var indented = false
    override var isFlipped: Bool { true }

    func configure(label: String, symbol: String, indented: Bool = false) {
        title = ""; image = nil; self.symbol = symbol
        self.indented = indented
        toolTip = label
        labelView.stringValue = label
        labelView.font = .systemFont(ofSize: indented ? 13 : 13.5, weight: .medium)
        labelView.lineBreakMode = .byTruncatingTail
        labelView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelView.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView); addSubview(labelView)
        disclosure.isHidden = true
        disclosure.setAccessibilityElement(false)
        addSubview(disclosure)
        updateStyle()
    }
    override func layout() {
        super.layout()
        let sidebarWidth = bounds.width + 20
        let compact = bounded((142 - sidebarWidth) / 58)
        let size: CGFloat = (indented ? 15 : 16) + compact * 3
        let leading: CGFloat = indented ? 26 : 12
        let x = leading + (bounds.midX - size / 2 - leading) * compact
        iconView.frame = NSRect(x: x, y: (bounds.height-size)/2, width: size, height: size)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size - 1, weight: .regular))
        let opacity = bounded((sidebarWidth - 86) / 62)
        labelView.alphaValue = opacity
        labelView.isHidden = opacity == 0
        let showsDisclosure = expanded != nil && sidebarWidth >= 145
        disclosure.isHidden = !showsDisclosure
        if let expanded, showsDisclosure {
            disclosure.frame = NSRect(x: bounds.width-23, y: (bounds.height-12)/2, width: 12, height: 12)
            disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
            disclosure.contentTintColor = CagePalette.muted
        }
        let labelX: CGFloat = max(38, iconView.frame.maxX+10)
        labelView.frame = NSRect(x: labelX, y: (bounds.height-20)/2, width: max(0,bounds.width-labelX-(showsDisclosure ? 29 : 9)), height: 20)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = labelView.bounds
        let overflow = labelView.intrinsicContentSize.width > labelView.bounds.width
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, (overflow ? NSColor.clear : NSColor.black).cgColor]
        fade.locations = [0, NSNumber(value: Double(max(0,1-10/max(1,labelView.bounds.width)))), 1]
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
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateStyle() }
    private func updateStyle() {
        let color = selected ? CagePalette.accentText : CagePalette.ink
        iconView.contentTintColor = color; labelView.textColor = color
        // The selection pill behind the rows carries the selected background.
        SidebarMotion.layers(0.12) {
            resolvingColors { layer?.backgroundColor = hover && !selected ? CagePalette.hover.cgColor : NSColor.clear.cgColor }
        }
        setAccessibilityValue(selected ? "已选择" : "")
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
        if animated && next != mode { SidebarMotion.fade(disc, 0.2) }
        mode = next
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let filled = next == .start && isEnabled
        resolvingColors {
            disc.backgroundColor = (filled ? CagePalette.accent : CagePalette.card).cgColor
            disc.borderColor = CagePalette.line.cgColor
            spinner.strokeColor = CagePalette.accent.cgColor
        }
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
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply(mode, animated: false) }
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
        resolvingColors { glyph.contents = image.layerContents(forContentsScale: scale) }
        glyph.contentsGravity = .resizeAspect
        CATransaction.commit()
    }
    override func highlight(_ flag: Bool) {
        SidebarMotion.layers(0.12) { disc.setAffineTransform(flag ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity) }
    }
}

/// The current guest's name, state and its single lifecycle control.
private final class SidebarMachineCard: NSView {
    var onOpen: (() -> Void)?
    let power = SidebarPowerButton(frame: .zero)
    private let dot = CALayer()
    private let halo = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "已停止")
    private var hover = false
    private var tracking: NSTrackingArea?
    private var compact = false
    private var dotColor = CagePalette.faint
    override var isFlipped: Bool { true }
    init(profile: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        name.stringValue = profile
        name.font = .systemFont(ofSize: 12.5, weight: .semibold); name.textColor = CagePalette.ink
        state.font = .systemFont(ofSize: 11.5); state.textColor = CagePalette.muted
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
        compact = bounds.width < 126
        name.isHidden = compact; state.isHidden = compact; dot.isHidden = compact; halo.isHidden = compact
        let side: CGFloat = compact ? 38 : 28
        power.frame = compact ? NSRect(x: (bounds.width-side)/2, y: (bounds.height-side)/2, width: side, height: side)
            : NSRect(x: bounds.width-side-10, y: (bounds.height-side)/2, width: side, height: side)
        let textWidth = max(0, power.frame.minX - 30)
        name.frame = NSRect(x: 25, y: 10, width: textWidth, height: 18)
        state.frame = NSRect(x: 25, y: 29, width: textWidth, height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: 11, y: 15, width: 8, height: 8)
        halo.frame = dot.frame.insetBy(dx: -4, dy: -4)
        CATransaction.commit()
        refreshChrome()
    }
    func update(running: Bool, ready: Bool, busy: Bool, setup: Bool, activity: String) {
        // A ready guest turns the card into the way back to its desktop.
        let returning = ready && !busy && !setup
        let text = setup ? "等待安装" : busy ? (["start": "正在启动…", "restart": "正在重启…", "stop": "正在停止…"][activity] ?? "正在处理…")
            : ready ? "回到桌面" : running ? "运行中 · 连接中" : "已停止"
        if state.stringValue != text { SidebarMotion.fade(state.layer, 0.16); state.stringValue = text }
        state.textColor = returning ? CagePalette.accentText : CagePalette.muted
        state.font = .systemFont(ofSize: 11.5, weight: returning ? .medium : .regular)
        dotColor = setup ? CagePalette.faint : busy || (running && !ready) ? CagePalette.accent : ready ? CagePalette.success : CagePalette.faint
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
        resolvingColors {
            dot.backgroundColor = dotColor.cgColor
            halo.backgroundColor = dotColor.withAlphaComponent(0.2).cgColor
        }
        CATransaction.commit()
    }
    private func refreshChrome() {
        SidebarMotion.layers(0.15) {
            resolvingColors {
                layer?.backgroundColor = compact ? NSColor.clear.cgColor : (hover ? CagePalette.group : CagePalette.card).cgColor
                layer?.borderColor = compact ? NSColor.clear.cgColor : CagePalette.line.cgColor
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshChrome(); refreshDot() }
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
    var color = CagePalette.muted
    var active = false
    var showsLabel = true { didSet { needsDisplay = true } }
    private var hover = false
    private var tracking: NSTrackingArea?
    private let name: String
    override var isFlipped: Bool { true }
    init(_ name: String) {
        self.name = name
        super.init(frame: .zero)
        title = ""; isBordered = false; bezelStyle = .inline
        wantsLayer = true; layer?.cornerRadius = 6
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ detail: String, _ state: Int) {
        active = state == 1 || state == 2 || state == 4
        color = state == 1 ? CagePalette.success : state == 2 ? CagePalette.accent : state == 4 ? CagePalette.danger : CagePalette.faint
        toolTip = "\(name)：\(detail)"; setAccessibilityValue(detail); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let label = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: hover ? CagePalette.ink : CagePalette.muted])
        let width = showsLabel ? 7 + 5 + label.size().width : 7
        let x = (bounds.width - width) / 2
        let rect = NSRect(x: x, y: bounds.midY-3.5, width: 7, height: 7)
        let path = NSBezierPath(ovalIn: rect)
        color.setStroke(); path.lineWidth = 1; path.stroke()
        if active { color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1.2, dy: 1.2)).fill() }
        if showsLabel { label.draw(at: NSPoint(x: rect.maxX + 5, y: bounds.midY - label.size().height / 2)) }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true; hoverChanged() }
    override func mouseExited(with event: NSEvent) { hover = false; hoverChanged() }
    private func hoverChanged() {
        SidebarMotion.layers(0.12) { resolvingColors { layer?.backgroundColor = hover ? CagePalette.hover.cgColor : NSColor.clear.cgColor } }
        needsDisplay = true
    }
}

private final class SidebarSpeedCircle: NSView {
    var upload = true { didSet { updateLabels() } }
    var value: Double? { didSet { updateLabels() } }
    private let arrow = NSTextField(labelWithString: "")
    private let speed = NSTextField(labelWithString: "")
    private let unit = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (label, size, color) in [(arrow, CGFloat(11), CagePalette.accent),
                                     (speed, 13, CagePalette.ink), (unit, 10, CagePalette.muted)] {
            label.alignment = .center
            label.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
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
        for (label, y) in [(arrow, CGFloat(4)), (speed, 19), (unit, 36)] {
            label.frame = NSRect(x: 1, y: y, width: max(0, bounds.width - 2), height: 16)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        CagePalette.line.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1
        ring.stroke()
    }
    private func updateLabels() {
        let parts = speedParts(value)
        arrow.stringValue = upload ? "↑" : "↓"
        arrow.textColor = upload ? CagePalette.accent : CagePalette.success
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

private final class SidebarTelemetry: NSView {
    var onSelect: ((String) -> Void)?
    private var up = "↑ —", down = "↓ —", total = "流量 —", coverage = "余量未知"
    private var usedPercent: Double?
    private var compactQuota = "—%"
    private let circles = [SidebarSpeedCircle(),SidebarSpeedCircle()]
    private let lamps = [SidebarLamp("代理"),SidebarLamp("环境"),SidebarLamp("虚拟机")]
    private let destinations = ["proxy", "checks", "desktop"]
    private let track = CALayer()
    private let fill = CALayer()
    override var isFlipped: Bool { true }
    static func preferredHeight(width: CGFloat) -> CGFloat { width < 146 ? 166 : 140 }
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("代理流量")
        circles[0].upload=true;circles[1].upload=false
        for circle in circles { circle.setAccessibilityElement(true);circle.setAccessibilityRole(.image);addSubview(circle) }
        for (lamp, destination) in zip(lamps, destinations) {
            lamp.target = self; lamp.action = #selector(lampPressed(_:))
            lamp.identifier = NSUserInterfaceItemIdentifier(destination)
            addSubview(lamp)
        }
        track.cornerRadius = 2
        fill.cornerRadius = 2; fill.anchorPoint = .zero
        layer?.addSublayer(track); track.addSublayer(fill)
        refreshBarColors()
    }
    private func refreshBarColors() {
        resolvingColors {
            track.backgroundColor = CagePalette.line.cgColor
            fill.backgroundColor = ((usedPercent ?? 0) > 85 ? CagePalette.warn : CagePalette.success).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin(); CATransaction.setDisableActions(true); refreshBarColors(); CATransaction.commit()
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
        up="↑ \(us.0) \(us.1)";down="↓ \(ds.0) \(ds.1)"
        circles[0].value=u;circles[1].value=d
        for (circle,text) in zip(circles,["上传：\(us.0) \(us.1)","下载：\(ds.0) \(ds.1)"]) { circle.toolTip=text;circle.setAccessibilityLabel(text) }
        let uploaded=(data["upload_24h"] as? NSNumber)?.doubleValue ?? 0,downloaded=(data["download_24h"] as? NSNumber)?.doubleValue ?? 0
        let quota=data["quota"] as? [String:Any]
        usedPercent=(quota?["used_percent"] as? NSNumber)?.doubleValue
        compactQuota=usedPercent.map { String(format:"%.0f%%",$0) } ?? "—%"
        if let used=(quota?["used"] as? NSNumber)?.doubleValue,let cap=(quota?["total"] as? NSNumber)?.doubleValue,let remaining=(quota?["remaining"] as? NSNumber)?.doubleValue {
            total="已用 \(byteText(used))"
            coverage="余量 \(byteText(remaining))"
            toolTip="订阅已用 \(byteText(used)) / \(byteText(cap))\n订阅更新：\(quota?["updated_at"] as? String ?? "未知")\n本地近24小时：↑ \(byteText(uploaded)) · ↓ \(byteText(downloaded))"
        } else {
            total="流量 \(byteText(uploaded+downloaded))"
            coverage="余量 未提供额度"
            toolTip="订阅未提供额度，余量和已用比例未知。\n流量为本机记录的近24小时累计。"
        }
        setAccessibilityValue("\(up)；\(down)；\(total)；\(coverage)；\(compactQuota) 已用")
        layoutQuota(animated: true)
        needsDisplay=true
    }
    private func layoutQuota(animated: Bool) {
        let wide = bounds.width >= 146
        let bar = CGRect(x: 14, y: 96, width: max(0, bounds.width-28), height: 4)
        let remaining = usedPercent.map { CGFloat(max(0, min(1, 1 - $0 / 100))) } ?? 0
        let apply = {
            self.track.frame = bar
            self.fill.bounds = CGRect(x: 0, y: 0, width: bar.width * remaining, height: bar.height)
            self.fill.position = .zero
            self.refreshBarColors()
        }
        track.isHidden = !wide
        if animated { SidebarMotion.layers(0.6, apply) }
        else { CATransaction.begin(); CATransaction.setDisableActions(true); apply(); CATransaction.commit() }
    }
    override func layout() {
        super.layout()
        let compact=bounds.width<146
        circles.forEach { $0.isHidden = !compact }
        if compact {
            let diameter:CGFloat=52
            circles[0].frame=NSRect(x:(bounds.width-diameter)/2,y:10,width:diameter,height:diameter)
            circles[1].frame=NSRect(x:(bounds.width-diameter)/2,y:68,width:diameter,height:diameter)
        }
        for (i, lamp) in lamps.enumerated() {
            lamp.showsLabel = !compact
            if compact {
                lamp.frame = NSRect(x: bounds.midX - 27 + CGFloat(i) * 18, y: bounds.height - 22, width: 18, height: 18)
            } else {
                let width = (bounds.width - 16) / 3
                lamp.frame = NSRect(x: 8 + CGFloat(i) * width, y: bounds.height - 26, width: width, height: 22)
            }
        }
        layoutQuota(animated: false)
    }
    override func draw(_ dirtyRect: NSRect) {
        CagePalette.line.setStroke();let path=NSBezierPath();path.move(to:NSPoint(x:12,y:0.5));path.line(to:NSPoint(x:bounds.width-12,y:0.5));path.lineWidth=1;path.stroke()
        func text(_ value:String,_ rect:NSRect,_ size:CGFloat,_ color:NSColor,_ centered:Bool=false) {
            let style=NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail;style.alignment = centered ? .center : .left
            (value as NSString).draw(in:rect,withAttributes:[.font:CagePalette.mono(size),.foregroundColor:color,.paragraphStyle:style])
        }
        if bounds.width>=146 {
            func speed(_ value: String, y: CGFloat, color: NSColor) {
                let line = NSMutableAttributedString(
                    string: value,
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: CagePalette.ink]
                )
                line.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
                line.draw(at: NSPoint(x: (bounds.width-line.size().width)/2, y: y))
            }
            speed(up, y: 12, color: CagePalette.accent)
            speed(down, y: 33, color: CagePalette.success)
            text(total, NSRect(x: 8, y: 60, width: bounds.width-16, height: 17), 12, CagePalette.ink, true)
            text(coverage, NSRect(x: 8, y: 77, width: bounds.width-16, height: 16), 11, CagePalette.muted, true)
        } else {
            text("\(compactQuota)已用",NSRect(x:2,y:126,width:bounds.width-4,height:16),11,CagePalette.ink,true)
            // The tooltip and accessibility value supply the used/remaining meaning.
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
    private var rows:[String:GuestNavigationButton]=[:]
    private let destinations = [("desktop","客机桌面","macwindow"),("management","虚拟机管理","internaldrive"),("proxy","代理管理","network"),("checks","环境检测","checkmark.shield")]
    private let management = [("space","存储空间","externaldrive"),("profiles","虚拟机切换","square.on.square"),("login","客机账户","person.crop.circle"),("timezone","时区","clock"),("input","输入法","keyboard")]
    private var managementExpanded = true
    private let brand=NSTextField(labelWithString:"VMac")
    private let logo=NSImageView()
    private let machine = SidebarMachineCard(profile: activeProfileName())
    private let pill = NSView()
    private var selected = "desktop"
    private var pillAnimating = false
    private let settingsRow = GuestNavigationButton()
    private let telemetry=SidebarTelemetry(frame:.zero)
    private var noticePopover: NSPopover?
    private var noticeGeneration = 0
    override var isFlipped: Bool { true }
    init() {
        super.init(frame:.zero)
        wantsLayer=true
        translatesAutoresizingMaskIntoConstraints=false
        brand.font = .systemFont(ofSize: 20, weight: .semibold);brand.textColor=CagePalette.ink;brand.lineBreakMode = .byTruncatingTail;brand.cell?.usesSingleLineMode=true;addSubview(brand)
        if let path=Bundle.main.path(forResource:"VMacMark",ofType:"pdf") { logo.image=NSImage(contentsOfFile:path) }
        logo.imageScaling = .scaleProportionallyUpOrDown;logo.setAccessibilityElement(false);addSubview(logo)
        machine.onOpen = { [weak self] in self?.choose("desktop") }
        machine.power.target = self; machine.power.action = #selector(powerPressed)
        addSubview(machine)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        addSubview(pill)
        refreshColors()
        for (id,label,symbol) in Array(destinations.prefix(2)) + management + Array(destinations.dropFirst(2)) {
            let button=GuestNavigationButton(title:label,target:self,action:#selector(selectRow(_:)))
            button.identifier=NSUserInterfaceItemIdentifier(id)
            button.configure(label: label, symbol: symbol, indented: isManagementPage(id))
            button.isBordered=false;button.bezelStyle = .inline;button.focusRingType = .default
            button.wantsLayer=true;button.layer?.cornerRadius=8;button.setAccessibilityLabel(label)
            if id == "management" {
                button.setAccessibilityRole(.disclosureTriangle)
                button.expanded = managementExpanded
            }
            addSubview(button);rows[id]=button
        }
        settingsRow.title = "设置"; settingsRow.target = self; settingsRow.action = #selector(selectRow(_:))
        settingsRow.identifier = NSUserInterfaceItemIdentifier("settings"); settingsRow.configure(label: "设置", symbol: "gearshape")
        settingsRow.isBordered = false; settingsRow.bezelStyle = .inline; settingsRow.wantsLayer = true
        settingsRow.layer?.cornerRadius = 8; settingsRow.setAccessibilityLabel("设置")
        addSubview(settingsRow)
        telemetry.onSelect = { [weak self] id in self?.choose(id) }
        addSubview(telemetry)
        select("desktop")
    }
    required init?(coder:NSCoder) { fatalError() }
    private func refreshColors() {
        resolvingColors {
            layer?.backgroundColor = CagePalette.sidebar.cgColor
            pill.layer?.backgroundColor = CagePalette.accentSoft.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    private func isManagementPage(_ id: String) -> Bool {
        management.contains { $0.0 == id }
    }
    private var highlighted: String {
        !managementExpanded && isManagementPage(selected) ? "management" : selected
    }
    private func layoutNavigation() {
        let compact = bounds.width < 146
        var y = machine.frame.maxY + 14
        let parentHeight: CGFloat = 32
        let childHeight: CGFloat = compact ? 27 : 30
        let count = managementExpanded ? management.count : 0
        let preferred = CGFloat(destinations.count) * (parentHeight + 2) + CGFloat(count) * (childHeight + 2)
        let scale = bounded((telemetry.frame.minY - y - 8) / preferred)
        func place(_ id: String, height: CGFloat) {
            let fitted = floor((height + 2) * scale)
            rows[id]?.frame = NSRect(x: 10, y: y, width: max(0, bounds.width-20), height: max(0, fitted-2))
            rows[id]?.needsLayout = true
            y += fitted
        }
        for (id, _, _) in destinations {
            place(id, height: parentHeight)
            if id == "management" {
                for (child, _, _) in management {
                    rows[child]?.isHidden = !managementExpanded
                    if managementExpanded { place(child, height: childHeight) }
                }
            }
        }
        if !pillAnimating { pill.frame = pillTarget() }
    }
    private func showManagement(_ expanded: Bool) {
        managementExpanded = expanded
        rows["management"]?.expanded = expanded
        layoutNavigation()
        for (key, button) in rows { button.selected = key == highlighted }
    }
    override func layout() {
        super.layout()
        let compact=bounds.width<146
        brand.isHidden=compact
        logo.frame=compact ? NSRect(x:(bounds.width-32)/2,y:20,width:32,height:32) : NSRect(x:14,y:22,width:28,height:28)
        brand.frame=NSRect(x:50,y:21,width:max(0,bounds.width-60),height:28)
        machine.frame = NSRect(x: 10, y: 64, width: max(0, bounds.width-20), height: compact ? 46 : 56)
        settingsRow.frame = NSRect(x: 10, y: bounds.height-44, width: max(0, bounds.width-20), height: 34)
        settingsRow.needsLayout = true
        let height = SidebarTelemetry.preferredHeight(width: bounds.width)
        telemetry.frame=NSRect(x:0,y:settingsRow.frame.minY-6-height,width:bounds.width,height:height)
        telemetry.needsLayout=true
        layoutNavigation()
    }
    private func pillTarget() -> NSRect {
        rows[highlighted]?.frame ?? .zero
    }
    @objc private func selectRow(_ sender:NSButton) { guard let id=sender.identifier?.rawValue else{return}; choose(id) }
    @objc private func powerPressed() { onSelect?(machine.power.mode == .restart ? "restart" : "start") }
    private func choose(_ id: String) {
        if id == "management" { showManagement(!managementExpanded) }
        else { onSelect?(id) }
    }
    func showNotice(_ text:String) {
        noticePopover?.close();noticeGeneration += 1
        guard !text.isEmpty,window?.isVisible == true else { return }
        let label=NSTextField(wrappingLabelWithString:text)
        label.font = .systemFont(ofSize:12);label.frame=NSRect(x:14,y:12,width:192,height:54)
        let controller=NSViewController();controller.view=NSView(frame:NSRect(x:0,y:0,width:220,height:78));controller.view.addSubview(label)
        let popover=NSPopover();popover.behavior = .transient;popover.animates = !SidebarMotion.reduced;popover.contentViewController=controller
        noticePopover=popover;popover.show(relativeTo:logo.bounds,of:logo,preferredEdge:.maxX)
        let generation=noticeGeneration
        DispatchQueue.main.asyncAfter(deadline:.now()+4) { [weak self] in
            if self?.noticeGeneration == generation { self?.noticePopover?.close() }
        }
    }
    func select(_ requested:String) {
        let id = requested == "lifecycle" ? "desktop" : requested
        guard rows[id] != nil, id != "management" else { return }
        let changed = id != selected
        selected = id
        if changed && !managementExpanded && isManagementPage(id) { showManagement(true) }
        for (key,button) in rows { button.selected = key == highlighted }
        guard changed else { return }
        guard window != nil, !pill.frame.isEmpty else { pill.frame = pillTarget(); return }
        pillAnimating = true
        SidebarMotion.animate(0.28, { pill.animator().frame = pillTarget() }, completion: { [weak self] in
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
