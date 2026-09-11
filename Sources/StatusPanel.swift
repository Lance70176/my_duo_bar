import AppKit

final class StatusRow: NSView {
    private let symbol = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    override var allowsVibrancy: Bool { true }

    init(height: CGFloat, compact: Bool = false) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: height))
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
        [symbol, titleField, detailField, valueField].forEach {
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
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            valueField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 10),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            valueField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor)
        ])
        detailField.isHidden = compact
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(symbol name: String, title: String, detail: String = "", value: String = "", active: Bool = true) {
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        symbol.contentTintColor = active ? .labelColor : .tertiaryLabelColor
        titleField.stringValue = title
        detailField.stringValue = detail
        valueField.stringValue = value
        toolTip = [title, value, detail].filter { !$0.isEmpty }.joined(separator: " · ")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(toolTip)
        [symbol, titleField, detailField, valueField].forEach { $0.setAccessibilityElement(false) }
    }
}

final class StatusPanel: NSView {
    static let panelSize = NSSize(width: 314, height: 312)
    private let wifi = StatusRow(height: 55)
    private let battery = StatusRow(height: 55)
    private let vpn = StatusRow(height: 35, compact: true)
    private let headphones = StatusRow(height: 35, compact: true)
    private let sound = StatusRow(height: 35, compact: true)
    private let focus = StatusRow(height: 35, compact: true)
    private let title = NSTextField(labelWithString: "DuoBar")
    private let mode = NSTextField(labelWithString: "此 Mac")
    override var allowsVibrancy: Bool { true }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.panelSize))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        mode.font = .systemFont(ofSize: 11)
        mode.textColor = .secondaryLabelColor
        let spacer = NSView()
        let header = NSStackView(views: [title, spacer, mode])
        header.orientation = .horizontal; header.alignment = .centerY
        header.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let separator = NSBox()
        separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let gap = NSView(); gap.heightAnchor.constraint(equalToConstant: 5).isActive = true
        let stack = NSStackView(views: [header, wifi, battery, separator, gap, vpn, headphones, sound, focus])
        stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 0
        for row in stack.arrangedSubviews { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5)
        ])
        update(SystemStatus())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: SystemStatus, preview: Bool = false) {
        mode.stringValue = preview ? "样例状态" : "此 Mac"
        wifi.update(symbol: state.wifi.symbol, title: state.wifi.route == .ethernet && !state.wifi.associated ? "以太网" : "Wi-Fi",
                    detail: state.wifi.title, value: state.wifi.associated ? state.wifi.signalQuality : "", active: state.wifi.associated || state.wifi.route == .ethernet)
        wifi.toolTip = state.wifi.detail
        let batterySymbol = state.battery.charging ? "battery.100percent.bolt" : "battery.75percent"
        battery.update(symbol: state.battery.present ? batterySymbol : "powerplug",
                       title: "电池", detail: state.battery.detail, value: state.battery.title)
        vpn.update(symbol: "key.horizontal", title: "VPN", value: state.vpn.title, active: state.vpn.active)
        vpn.toolTip = state.vpn.hasUnidentifiedTunnel ? "检测到网络隧道，但 macOS 未提供可确认的 VPN 名称；不会据此点亮 VPN 图标。" : state.vpn.title
        headphones.update(symbol: "headphones", title: "耳机", value: state.audio.headphoneTitle, active: state.audio.headphoneActive)
        sound.update(symbol: state.audio.muted == true ? "speaker.slash.fill" : "speaker.wave.2",
                     title: "声音", value: state.audio.soundTitle)
        sound.toolTip = state.audio.outputName + " · " + state.audio.soundTitle
        focus.update(symbol: state.focus.symbol, title: "专注", value: state.focus.title, active: state.focus.isActive)
        if case .unavailable(let reason) = state.focus { focus.toolTip = reason }
    }
}

final class LargeIconView: NSView {
    var status = SystemStatus.preview() { didSet { needsDisplay = true } }
    var layout = DotLayout() { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        DuoIcon.draw(status: status, layout: layout, in: bounds, color: .labelColor)
    }
}
