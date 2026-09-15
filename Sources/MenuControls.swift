import AppKit

/// A switch drawn by hand. NSSwitch inside a menu renders in the inactive (gray) style because menu windows
/// never become key, so an "on" switch looked off. This one always shows the accent color when on.
final class MenuSwitch: NSControl {
    static let size = NSSize(width: 32, height: 19)
    var isOn: Bool { didSet { needsDisplay = true; setAccessibilityValue(isOn) } }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(isOn)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let fill = isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.16)
        fill.withAlphaComponent(isEnabled ? fill.alphaComponent : fill.alphaComponent * 0.5).setFill()
        track.fill()
        let inset: CGFloat = 2
        let diameter = bounds.height - inset * 2
        let x = isOn ? bounds.maxX - inset - diameter : bounds.minX + inset
        let knob = NSBezierPath(ovalIn: NSRect(x: x, y: inset, width: diameter, height: diameter))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()
        NSColor.white.setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Flips the state and fires the action, as a click would.
    func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        if let action { sendAction(action, to: target) }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }
}
