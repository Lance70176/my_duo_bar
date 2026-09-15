import AppKit

final class StatusRow: NSButton {
    var destination: SystemSettings.Page
    var onActivate: (() -> Void)?
    private var hover = false
    private var hoverTracking: NSTrackingArea?
    private let chevron = NSImageView()
    private let symbol = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    override var allowsVibrancy: Bool { true }

    init(height: CGFloat, destination: SystemSettings.Page, compact: Bool = false) {
        self.destination = destination
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .default
        target = self; action = #selector(activateRow)
        setAccessibilityIdentifier("status-" + destination.rawValue)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        chevron.contentTintColor = .tertiaryLabelColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        symbol.imageScaling = .scaleProportionallyDown
        titleField.font = .systemFont(ofSize: 13, weight: compact ? .regular : .semibold)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        valueField.font = .systemFont(ofSize: 12, weight: .medium)
        valueField.textColor = .secondaryLabelColor
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [symbol, titleField, detailField, valueField, chevron].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            symbol.widthAnchor.constraint(equalToConstant: compact ? 19 : 24),
            symbol.heightAnchor.constraint(equalToConstant: compact ? 19 : 24),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: compact ? 0 : -8),
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: compact ? 78 : 145),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            valueField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 10),
            valueField.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            valueField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        detailField.isHidden = compact
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hover = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hover || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    func setNavigationEnabled(_ enabled: Bool) {
        isEnabled = enabled
        chevron.isHidden = !enabled
        if !enabled { hover = false }
        needsDisplay = true
    }
    @objc private func activateRow() { if isEnabled { onActivate?() } }

    func update(symbol name: String, title: String, detail: String = "", value: String = "", active: Bool = true) {
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        symbol.contentTintColor = active ? .labelColor : .tertiaryLabelColor
        titleField.stringValue = title
        detailField.stringValue = detail
        valueField.stringValue = value
        toolTip = [title, value, detail].filter { !$0.isEmpty }.joined(separator: " · ")
        setAccessibilityElement(true)
        setAccessibilityRole(isEnabled ? .button : .staticText)
        setAccessibilityLabel(toolTip)
        setAccessibilityHelp(isEnabled ? L10n.open(destination.title) : nil)
        [symbol, titleField, detailField, valueField, chevron].forEach { $0.setAccessibilityElement(false) }
    }
}

/// "MyDuoBar · This Mac" line at the top of the status menu.
final class StatusPanelHeader: NSView {
    static let headerSize = NSSize(width: 314, height: 35)
    private let title = NSTextField(labelWithString: "MyDuoBar")
    private let mode = NSTextField(labelWithString: L10n.thisMac)
    override var allowsVibrancy: Bool { true }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.headerSize))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        mode.font = .systemFont(ofSize: 11)
        mode.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, NSView(), mode])
        header.orientation = .horizontal; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false; addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            header.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(preview: Bool = false) { mode.stringValue = preview ? L10n.sampleStatus : L10n.thisMac }
}

/// The Focus row after Sound. Wi-Fi, Battery, VPN, Headphones and Sound are native menu items so they can open submenus.
final class StatusPanel: NSView {
    static let width: CGFloat = 314
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    private let focus = StatusRow(height: 35, destination: .focus, compact: true)
    override var allowsVibrancy: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 35 + 21))
        let stack = NSStackView(views: [focus])
        stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 0
        focus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor)
        ])
        focus.onActivate = { [weak self] in self?.onOpenSettings?(.focus) }
        update(SystemStatus())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: SystemStatus) {
        focus.update(symbol: state.focus.symbol, title: L10n.focus, value: state.focus.title, active: state.focus.isActive)
        if case .unavailable(let reason) = state.focus { focus.toolTip = reason }
    }
}

final class LargeIconView: NSView {
    var status = SystemStatus.preview() { didSet { needsDisplay = true } }
    var showVolume = true { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        DuoIcon.draw(status: status, showVolume: showVolume, in: bounds, color: .labelColor)
    }
}
