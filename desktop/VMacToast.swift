import Cocoa

/// A short message floating over the bottom of the window: transfer results
/// and errors, shown without taking the user away from the guest. It grows to
/// two lines for a longer message; anything beyond that is cut, with the full
/// text in the tooltip.
final class VMacToastView: NSView {
    private var model = VMacToastModel()
    private var generation = 0
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        alphaValue = 0
        isHidden = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = NSColor(srgbRed: 248 / 255, green: 113 / 255, blue: 113 / 255, alpha: 1)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭提示")
        close.isBordered = false
        close.contentTintColor = NSColor(white: 1, alpha: 0.7)
        close.target = self; close.action = #selector(dismiss)
        for view in [icon, label, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let oneLine = heightAnchor.constraint(equalToConstant: 32)
        oneLine.priority = .defaultLow
        NSLayoutConstraint.activate([
            oneLine,
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16),
        ])
        errorLayout = [label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                       label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8)]
        infoLayout = [label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)]
    }
    required init?(coder: NSCoder) { fatalError() }
    private var errorLayout: [NSLayoutConstraint] = []
    private var infoLayout: [NSLayoutConstraint] = []
    private static let maxWidth: CGFloat = 560
    /// What the icon, the close button and the margins take from the width.
    private static let errorInset: CGFloat = 68, infoInset: CGFloat = 32

    // In a narrow window the label gets less room than the widest toast
    // allows; it then has to wrap at the width it was really given.
    override func layout() {
        super.layout()
        guard label.frame.width < label.intrinsicContentSize.width - 0.5 else { return }
        label.preferredMaxLayoutWidth = label.frame.width
        super.layout()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor(srgbRed: 15 / 255, green: 17 / 255, blue: 21 / 255, alpha: 0.92).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
    }
    // An ordinary notice never takes clicks away from the guest underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        model.visible && model.kind == .error ? super.hitTest(point) : nil
    }

    func show(_ text: String, kind: VMacToastKind) {
        let lifetime = model.show(text, kind: kind)
        generation += 1
        guard model.visible else { setShown(false); return }
        let isError = model.kind == .error
        label.preferredMaxLayoutWidth = Self.maxWidth - (isError ? Self.errorInset : Self.infoInset)
        label.stringValue = model.text
        toolTip = model.text
        icon.isHidden = !isError; close.isHidden = !isError
        NSLayoutConstraint.deactivate(isError ? infoLayout : errorLayout)
        NSLayoutConstraint.activate(isError ? errorLayout : infoLayout)
        setShown(true)
        if let window {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: model.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        guard let lifetime else { return }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            guard let self, self.generation == current else { return }
            self.model.dismiss()
            self.setShown(false)
        }
    }
    @objc private func dismiss() {
        generation += 1
        model.dismiss()
        setShown(false)
    }
    private func setShown(_ shown: Bool) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shown && isHidden {
            isHidden = false
            if !reduced, let layer { layer.setAffineTransform(CGAffineTransform(translationX: 0, y: -6)) }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            context.allowsImplicitAnimation = true
            animator().alphaValue = shown ? 1 : 0
            layer?.setAffineTransform(.identity)
        }, completionHandler: { [weak self] in
            guard let self, !self.model.visible else { return }
            self.isHidden = true
        })
    }
}
