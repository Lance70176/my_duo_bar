import AppKit

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

final class LargeIconView: NSView {
    var status = SystemStatus.preview() { didSet { needsDisplay = true } }
    var showVolume = true { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        DuoIcon.draw(status: status, showVolume: showVolume, in: bounds, color: .labelColor)
    }
}
