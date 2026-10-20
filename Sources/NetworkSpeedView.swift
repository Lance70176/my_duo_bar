import AppKit

/// Upload over download in two small lines, drawn to the right of the icon in the menu bar.
final class NetworkSpeedView: NSView {
    /// Wide enough for "↓ 999 KB/s" so the status item never changes width as the numbers move.
    static let width: CGFloat = 50
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    var speed = NetworkSpeed() {
        didSet { if speed != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func lines(for speed: NetworkSpeed) -> (upload: String, download: String) {
        ("↑ " + NetworkSpeed.format(speed.upload), "↓ " + NetworkSpeed.format(speed.download))
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        let (upload, download) = Self.lines(for: speed)
        let lineHeight = ceil(Self.font.ascender - Self.font.descender)
        let top = bounds.midY + lineHeight - 1
        for (index, text) in [upload, download].enumerated() {
            let string = NSAttributedString(string: text, attributes: attributes)
            string.draw(at: NSPoint(x: 1, y: top - CGFloat(index + 1) * lineHeight))
        }
    }
}
