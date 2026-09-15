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

/// A slider drawn by hand for the same reason as `MenuSwitch`: system sliders lose their accent fill in menus.
/// Sends its action continuously while dragging.
final class MenuSlider: NSControl {
    static let height: CGFloat = 20
    static let knobDiameter: CGFloat = 16
    /// VoiceOver and the scroll wheel step like the volume keys: sixteen steps.
    static let step: Float = 1 / 16

    var value: Float = 0 {
        didSet {
            if value != max(0, min(1, value)) { value = max(0, min(1, value)) }
            needsDisplay = true
            setAccessibilityValue(NSNumber(value: value))
        }
    }
    /// Draws the fill in gray, e.g. while the output is muted, without disabling the slider.
    var dimmed = false { didSet { needsDisplay = true } }
    private(set) var isTracking = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityValue(NSNumber(value: value))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    private var travel: ClosedRange<CGFloat> {
        let radius = Self.knobDiameter / 2
        return radius...max(radius, bounds.width - radius)
    }

    /// The value for a point along the track, in the slider's coordinates.
    func value(atX x: CGFloat) -> Float {
        let range = travel
        guard range.upperBound > range.lowerBound else { return 0 }
        return Float((min(max(x, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    override func draw(_ dirtyRect: NSRect) {
        let range = travel
        let knobX = range.lowerBound + CGFloat(value) * (range.upperBound - range.lowerBound)
        let trackHeight: CGFloat = 4
        let track = NSRect(x: range.lowerBound, y: bounds.midY - trackHeight / 2,
                           width: range.upperBound - range.lowerBound, height: trackHeight)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        let fillColor = dimmed || !isEnabled ? NSColor.labelColor.withAlphaComponent(0.35) : NSColor.controlAccentColor
        fillColor.setFill()
        var filled = track
        filled.size.width = knobX - track.minX
        NSBezierPath(roundedRect: filled, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        guard isEnabled else { return }
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX - Self.knobDiameter / 2, y: bounds.midY - Self.knobDiameter / 2,
                                               width: Self.knobDiameter, height: Self.knobDiameter))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 2
        shadow.set()
        NSColor.white.setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        knob.lineWidth = 0.5
        knob.stroke()
    }

    /// Moves to a value and fires the action, as a drag would.
    func setValueFromUser(_ newValue: Float) {
        guard isEnabled else { return }
        value = newValue
        if let action { sendAction(action, to: target) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTracking = true
        defer { isTracking = false }
        setValueFromUser(value(atX: convert(event.locationInWindow, from: nil).x))
        // Track the drag here, like NSSlider does, so it works inside menu tracking.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            setValueFromUser(value(atX: convert(next.locationInWindow, from: nil).x))
            if next.type == .leftMouseUp { break }
        }
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY * CGFloat(Self.step)
        guard delta != 0 else { return }
        setValueFromUser(value + Float(event.isDirectionInvertedFromDevice ? -delta : delta))
    }
    override func accessibilityPerformIncrement() -> Bool { setValueFromUser(value + Self.step); return isEnabled }
    override func accessibilityPerformDecrement() -> Bool { setValueFromUser(value - Self.step); return isEnabled }
}

/// A submenu row with a round badge (accent when on), a title, a status line and a switch.
/// The whole row toggles. VPN and mute rows share it.
class SwitchRowView: NSView {
    let toggleSwitch = MenuSwitch(isOn: false)
    var onToggle: (() -> Void)?
    private let badge = NSView()
    private let glyph = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    override var allowsVibrancy: Bool { true }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 42))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 12
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [badge, titleField, detailField, toggleSwitch] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        glyph.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(glyph)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            glyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 9),
            titleField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -10),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -10),
            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var titleText: String { titleField.stringValue }
    var detailText: String { detailField.stringValue }
    var symbolName: String?

    func configure(symbol: String, title: String, detail: String, isOn: Bool, isEnabled: Bool, help: String) {
        if symbol != symbolName {
            symbolName = symbol
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        }
        titleField.stringValue = title
        detailField.stringValue = detail
        toggleSwitch.isOn = isOn
        toggleSwitch.isEnabled = isEnabled
        applyColors()
        setAccessibilityLabel(title + ", " + detail)
        setAccessibilityValue(isOn)
        setAccessibilityHelp(help)
    }

    private func applyColors() {
        let on = toggleSwitch.isOn
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).cgColor
        }
        glyph.contentTintColor = on ? .white : .labelColor
    }
    override func viewDidChangeEffectiveAppearance() { applyColors() }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {
        if enclosingMenuItem?.isHighlighted == true {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), toggleSwitch.isEnabled else { return }
        onToggle?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard toggleSwitch.isEnabled else { return false }
        onToggle?(); return true
    }
}
