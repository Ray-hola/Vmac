import Cocoa

enum CagePalette {
    static let paper = NSColor(srgbRed: 250/255, green: 249/255, blue: 245/255, alpha: 1)
    static let sidebar = NSColor(srgbRed: 240/255, green: 238/255, blue: 230/255, alpha: 1)
    static let ink = NSColor(srgbRed: 38/255, green: 38/255, blue: 36/255, alpha: 1)
    static let muted = NSColor(srgbRed: 113/255, green: 109/255, blue: 100/255, alpha: 1)
    static let accent = NSColor(srgbRed: 166/255, green: 77/255, blue: 47/255, alpha: 1)
    static let line = NSColor(srgbRed: 213/255, green: 208/255, blue: 195/255, alpha: 1)
    static let success = NSColor(srgbRed: 82/255, green: 112/255, blue: 82/255, alpha: 1)
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

private func bounded(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

private final class GuestNavigationButton: NSButton {
    var selected = false { didSet { updateStyle() } }
    private var hover = false
    private var tracking: NSTrackingArea?
    private let iconView = NSImageView()
    private let labelView = NSTextField(labelWithString: "")
    private let fade = CAGradientLayer()
    private var symbol = ""
    override var isFlipped: Bool { true }

    func configure(label: String, symbol: String) {
        title = ""; image = nil; self.symbol = symbol
        toolTip = label
        labelView.stringValue = label
        labelView.font = .systemFont(ofSize: 14, weight: .medium)
        labelView.lineBreakMode = .byTruncatingTail
        labelView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelView.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView); addSubview(labelView)
    }
    override func layout() {
        super.layout()
        let sidebarWidth = bounds.width + 20
        let compact = bounded((142 - sidebarWidth) / 58)
        let size: CGFloat = 16 + compact * 4
        let x = 12 + (bounds.midX - size / 2 - 12) * compact
        iconView.frame = NSRect(x: x, y: (bounds.height-size)/2, width: size, height: size)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        let opacity = bounded((sidebarWidth - 86) / 62)
        labelView.alphaValue = opacity
        labelView.isHidden = opacity == 0
        let labelX: CGFloat = max(42,iconView.frame.maxX+8)
        labelView.frame = NSRect(x: labelX, y: (bounds.height-22)/2, width: max(0,bounds.width-labelX-9), height: 22)
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
    private func updateStyle() {
        let color = selected ? CagePalette.accent : CagePalette.ink
        iconView.contentTintColor = color; labelView.textColor = color
        layer?.backgroundColor = selected ? CagePalette.accent.withAlphaComponent(0.09).cgColor : hover ? CagePalette.ink.withAlphaComponent(0.045).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = CagePalette.accent.withAlphaComponent(0.22).cgColor
        setAccessibilityValue(selected ? "已选择" : "")
    }
}

private final class SidebarLamp: NSView {
    private var color = CagePalette.muted
    private var active = false
    init(_ name: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ name: String, _ detail: String, _ state: Int) {
        active = state == 1 || state == 2 || state == 4
        color = state == 1 ? CagePalette.success : state == 2 ? CagePalette.accent : state == 4 ? .systemRed : CagePalette.muted.withAlphaComponent(0.45)
        toolTip = "\(name)：\(detail)";setAccessibilityLabel(toolTip);needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: bounds.midX-3.5,y: bounds.midY-3.5,width: 7,height: 7)
        let path = NSBezierPath(ovalIn: rect)
        color.setStroke();path.lineWidth = 1;path.stroke()
        if active { color.setFill();NSBezierPath(ovalIn: rect.insetBy(dx: 1.4,dy: 1.4)).fill() }
    }
}

private final class SidebarSpeedCircle: NSView {
    var upload = true
    var value: Double? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1,dy: 1)
        CagePalette.line.setStroke();let ring=NSBezierPath(ovalIn: rect);ring.lineWidth=1;ring.stroke()
        let speed = speedParts(value)
        let style = NSMutableParagraphStyle();style.alignment = .center
        func text(_ text: String,_ y: CGFloat,_ font: CGFloat,_ color: NSColor) {
            (text as NSString).draw(in: NSRect(x: 1,y: y,width: bounds.width-2,height: 18),withAttributes: [.font:CagePalette.mono(font,weight:.medium),.foregroundColor:color,.paragraphStyle:style])
        }
        text(upload ? "↑" : "↓",4,11,upload ? CagePalette.accent : CagePalette.success)
        text(speed.0,19,13,CagePalette.ink)
        text(speed.1,36,10,CagePalette.muted)
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
    private let up = NSTextField(labelWithString:"↑ —")
    private let down = NSTextField(labelWithString:"↓ —")
    private let total = NSTextField(labelWithString:"流量 —")
    private let coverage = NSTextField(labelWithString:"余量未知")
    private var usedPercent: Double?
    private var compactQuota = "—%"
    private let circles = [SidebarSpeedCircle(),SidebarSpeedCircle()]
    private let lamps = [SidebarLamp("代理"),SidebarLamp("环境"),SidebarLamp("虚拟机")]
    private let labels = ["代理","环境","虚拟机"].map { NSTextField(labelWithString:$0) }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("代理流量")
        for label in [up,down,total,coverage] {
            label.font=CagePalette.mono(12);label.textColor=CagePalette.ink;label.lineBreakMode = .byTruncatingTail
        }
        coverage.font=CagePalette.mono(11);coverage.textColor=CagePalette.muted
        circles[0].upload=true;circles[1].upload=false
        for circle in circles { circle.setAccessibilityElement(true);circle.setAccessibilityRole(.image);addSubview(circle) }
        for (lamp,label) in zip(lamps,labels) {
            addSubview(lamp);label.font = .systemFont(ofSize:11);label.textColor=CagePalette.muted;label.alignment = .center
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateStatus(running: Bool,ready: Bool,busy: Bool,network: String,failed: Bool) {
        lamps[1].update("环境",failed ? "检查失败" : busy ? "正在检查" : ready ? "已就绪" : "未就绪",failed ? 4 : busy ? 2 : ready ? 1 : 0)
        lamps[2].update("虚拟机",running ? "运行中" : "已停止",running ? 1 : 0)
        // Proxy health is updated independently by the aggregate counter sampler.
        networkLabel=network;environmentBusy=busy;refreshProxyLamp()
    }
    private var networkLabel="等待检测"
    private var proxyAvailable=false
    private var environmentBusy=false
    private func refreshProxyLamp() {
        let open=networkLabel == "外网已放行"
        lamps[0].update("代理",proxyAvailable ? networkLabel : "核心未连接",proxyAvailable ? (open ? 1 : 2) : (environmentBusy ? 2 : 0))
    }
    func updateTraffic(_ data:[String:Any]) {
        proxyAvailable=data["available"] as? Bool ?? false;refreshProxyLamp()
        let u=(data["upload_rate"] as? NSNumber)?.doubleValue,d=(data["download_rate"] as? NSNumber)?.doubleValue
        let us=speedParts(u),ds=speedParts(d)
        up.stringValue="↑ \(us.0) \(us.1)";down.stringValue="↓ \(ds.0) \(ds.1)"
        circles[0].value=u;circles[1].value=d
        for (circle,text) in zip(circles,["上传：\(us.0) \(us.1)","下载：\(ds.0) \(ds.1)"]) { circle.toolTip=text;circle.setAccessibilityLabel(text) }
        let uploaded=(data["upload_24h"] as? NSNumber)?.doubleValue ?? 0,downloaded=(data["download_24h"] as? NSNumber)?.doubleValue ?? 0
        let quota=data["quota"] as? [String:Any]
        usedPercent=(quota?["used_percent"] as? NSNumber)?.doubleValue
        compactQuota=usedPercent.map { String(format:"%.0f%%",$0) } ?? "—%"
        if let used=(quota?["used"] as? NSNumber)?.doubleValue,let cap=(quota?["total"] as? NSNumber)?.doubleValue,let remaining=(quota?["remaining"] as? NSNumber)?.doubleValue {
            total.stringValue="流量 \(byteText(used))"
            coverage.stringValue="余量 \(byteText(remaining))"
            toolTip="订阅已用 \(byteText(used)) / \(byteText(cap))\n订阅更新：\(quota?["updated_at"] as? String ?? "未知")\n本地近24小时：↑ \(byteText(uploaded)) · ↓ \(byteText(downloaded))"
        } else {
            total.stringValue="流量 \(byteText(uploaded+downloaded))"
            coverage.stringValue="余量 未提供额度"
            toolTip="订阅未提供额度，余量和已用比例未知。\n流量为本机记录的近24小时累计。"
        }
        total.toolTip=toolTip;coverage.toolTip=toolTip
        setAccessibilityValue("\(up.stringValue)；\(down.stringValue)；\(total.stringValue)；\(coverage.stringValue)；\(compactQuota) 已用")
        needsLayout=true;needsDisplay=true
    }
    override func layout() {
        super.layout()
        let compact=bounds.width<146
        [up,down,total,coverage].forEach { $0.isHidden=compact }
        circles.forEach { $0.isHidden = !compact }
        if compact {
            let diameter:CGFloat=52
            circles[0].frame=NSRect(x:(bounds.width-diameter)/2,y:4,width:diameter,height:diameter)
            circles[1].frame=NSRect(x:(bounds.width-diameter)/2,y:64,width:diameter,height:diameter)
        } else {
            up.frame=NSRect(x:14,y:7,width:bounds.width-28,height:17)
            down.frame=NSRect(x:14,y:30,width:bounds.width-28,height:17)
            total.frame=NSRect(x:14,y:61,width:bounds.width-28,height:17)
            coverage.frame=NSRect(x:14,y:81,width:bounds.width-28,height:15)
        }
        let showLabels=bounds.width>=146
        for i in 0..<3 {
            let width:CGFloat=showLabels ? (bounds.width-20)/3 : 14
            let x:CGFloat=showLabels ? 10+CGFloat(i)*width : bounds.midX-21+CGFloat(i)*14
            lamps[i].frame=NSRect(x:x,y:bounds.height-(showLabels ? 40 : 24),width:width,height:12)
            labels[i].isHidden = !showLabels
            labels[i].frame=NSRect(x:x-2,y:bounds.height-25,width:width+4,height:14)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        CagePalette.line.setStroke();let path=NSBezierPath();path.move(to:NSPoint(x:12,y:0));path.line(to:NSPoint(x:bounds.width-12,y:0));path.lineWidth=1;path.stroke()
        func text(_ value:String,_ rect:NSRect,_ size:CGFloat,_ color:NSColor,_ centered:Bool=false) {
            let style=NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail;style.alignment = centered ? .center : .left
            (value as NSString).draw(in:rect,withAttributes:[.font:CagePalette.mono(size),.foregroundColor:color,.paragraphStyle:style])
        }
        if bounds.width>=146 {
            func speed(_ value: String, y: CGFloat, color: NSColor) {
                let line = NSMutableAttributedString(
                    string: value,
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold), .foregroundColor: CagePalette.ink]
                )
                line.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
                line.draw(at: NSPoint(x: (bounds.width-line.size().width)/2, y: y))
            }
            speed(up.stringValue, y: 6, color: CagePalette.accent)
            speed(down.stringValue, y: 29, color: CagePalette.success)
            text(total.stringValue, NSRect(x: 8, y: 58, width: bounds.width-16, height: 23), 16, CagePalette.ink, true)
            text(coverage.stringValue, NSRect(x: 8, y: 83, width: bounds.width-16, height: 20), 13, CagePalette.muted, true)
        }
        if bounds.width>=146 {
            let bar=NSRect(x:14,y:108,width:bounds.width-28,height:6)
            CagePalette.line.setFill();NSBezierPath(roundedRect:bar,xRadius:2,yRadius:2).fill()
            if let usedPercent {
                (usedPercent>85 ? CagePalette.accent : CagePalette.success).setFill()
                NSBezierPath(roundedRect:NSRect(x:bar.minX,y:bar.minY,width:bar.width*CGFloat(max(0,1-usedPercent/100)),height:bar.height),xRadius:2,yRadius:2).fill()
            }
        } else {
            text("\(compactQuota)已用",NSRect(x:2,y:120,width:bounds.width-4,height:16),12,CagePalette.ink,true)
            // The tooltip and accessibility value supply the used/remaining meaning.
        }
        if bounds.width>=146 {
            let width=(bounds.width-20)/3
            for i in 0..<3 { text(labels[i].stringValue,NSRect(x:8+CGFloat(i)*width,y:bounds.height-25,width:width+4,height:18),11,CagePalette.muted,true) }
        }
    }
}

final class CageGuestSidebar: NSView {
    var onSelect:((String)->Void)?
    private var rows:[String:GuestNavigationButton]=[:]
    private let brand=NSTextField(labelWithString:"VMac_")
    private let logo=NSImageView()
    private let startButton = NSButton()
    private let restartButton = NSButton()
    private let telemetry=SidebarTelemetry(frame:.zero)
    private var noticePopover: NSPopover?
    private var noticeGeneration = 0
    override var isFlipped: Bool { true }
    init() {
        super.init(frame:.zero)
        wantsLayer=true;layer?.backgroundColor=CagePalette.sidebar.cgColor
        translatesAutoresizingMaskIntoConstraints=false
        brand.font = .systemFont(ofSize: 24, weight: .semibold);brand.textColor=CagePalette.ink;brand.lineBreakMode = .byTruncatingTail;brand.cell?.usesSingleLineMode=true;addSubview(brand)
        if let path=Bundle.main.path(forResource:"VMacMark",ofType:"pdf") { logo.image=NSImage(contentsOfFile:path) }
        logo.imageScaling = .scaleProportionallyUpOrDown;logo.setAccessibilityElement(false);addSubview(logo)
        let destinations=[("desktop","客机桌面","macwindow"),("space","虚拟机管理","internaldrive"),("proxy","代理管理","network")]
        for (id,label,symbol) in destinations {
            let button=GuestNavigationButton(title:label,target:self,action:#selector(selectRow(_:)))
            button.identifier=NSUserInterfaceItemIdentifier(id);button.configure(label:label,symbol:symbol)
            button.isBordered=false;button.bezelStyle = .inline;button.focusRingType = .default
            button.wantsLayer=true;button.layer?.cornerRadius=5;button.setAccessibilityLabel(label)
            addSubview(button);rows[id]=button
        }
        for (button, label, symbol, id) in [
            (startButton, "启动", "play.fill", "start"),
            (restartButton, "重启", "arrow.clockwise", "restart")
        ] {
            button.title = label
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.target = self
            button.action = #selector(selectRow(_:))
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.isEnabled = false
            addSubview(button)
        }
        addSubview(telemetry)
        select("desktop")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let compact=bounds.width<146
        brand.isHidden=compact
        brand.stringValue="VMac_"
        brand.font = .systemFont(ofSize: 24, weight: .semibold)
        logo.frame=compact ? NSRect(x:(bounds.width-36)/2,y:23,width:36,height:36) : NSRect(x:14,y:26,width:32,height:32)
        brand.frame=NSRect(x:51,y:26,width:max(0,bounds.width-60),height:32)
        let compactButtons = bounds.width < 160
        for button in [startButton, restartButton] {
            button.imagePosition = compactButtons ? .imageOnly : .imageLeading
        }
        let buttonWidth = (bounds.width - 24) / 2
        startButton.frame = NSRect(x: 9, y: 69, width: buttonWidth, height: 30)
        restartButton.frame = NSRect(x: 15 + buttonWidth, y: 69, width: buttonWidth, height: 30)
        for (i,id) in ["desktop","space","proxy"].enumerated() {
            rows[id]?.frame=NSRect(x:10,y:113+CGFloat(i)*45,width:max(0,bounds.width-20),height:40)
            rows[id]?.needsLayout=true
        }
        telemetry.frame=NSRect(x:0,y:bounds.height-174,width:bounds.width,height:162)
        telemetry.needsLayout=true
    }
    @objc private func selectRow(_ sender:NSButton) { guard let id=sender.identifier?.rawValue else{return};if rows[id] != nil { select(id) };onSelect?(id) }
    func showNotice(_ text:String) {
        noticePopover?.close();noticeGeneration += 1
        guard !text.isEmpty,window?.isVisible == true else { return }
        let label=NSTextField(wrappingLabelWithString:text)
        label.font = .systemFont(ofSize:12);label.frame=NSRect(x:14,y:12,width:192,height:54)
        let controller=NSViewController();controller.view=NSView(frame:NSRect(x:0,y:0,width:220,height:78));controller.view.addSubview(label)
        let popover=NSPopover();popover.behavior = .transient;popover.animates=false;popover.contentViewController=controller
        noticePopover=popover;popover.show(relativeTo:logo.bounds,of:logo,preferredEdge:.maxX)
        let generation=noticeGeneration
        DispatchQueue.main.asyncAfter(deadline:.now()+4) { [weak self] in
            if self?.noticeGeneration == generation { self?.noticePopover?.close() }
        }
    }
    func select(_ id:String) { for (key,button) in rows {button.selected=key==id} }
    func update(running:Bool,ready:Bool,busy:Bool,networkLabel:String,failed:Bool=false,setup:Bool=false) {
        startButton.isEnabled = !setup && !running && !busy
        restartButton.isEnabled = !setup && running && !busy
        telemetry.updateStatus(running:running,ready:ready,busy:busy,network:networkLabel,failed:failed)
    }
    func updateTraffic(_ data:[String:Any]) { telemetry.updateTraffic(data) }
}
