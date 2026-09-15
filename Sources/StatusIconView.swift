import AppKit
import QuartzCore

/// WindowServer animates the ring independently of status queries and menu tracking.
///
/// The stroked layers share one path that runs twice around the capsule, so a turn can slide the
/// visible window one full lap without ever wrapping past the end of the path. The mute bar is
/// stroked the same way, so it travels with the arc.
final class StatusIconView: NSView {
    /// How long the headphone symbol replaces Wi-Fi after headphones connect.
    static let headphoneGlimpse: TimeInterval = 2.2

    private let outer = CALayer()
    private let track = CAShapeLayer()
    private let battery = CAShapeLayer()
    private let sweep = CAShapeLayer()
    private let center = CALayer()
    private let dots = (0..<DuoIcon.markCount).map { _ in CAShapeLayer() }
    private let bar = CAShapeLayer()
    private var status: SystemStatus?
    private var showVolume = true
    /// The symbol shown in place of Wi-Fi while headphones have just connected.
    private var glimpseSymbol: String?
    private var glimpseGeneration = 0
    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Stroke fractions are measured against the two-lap path.
    private static let laps: CGFloat = 2
    private static let trackEnd = DuoIcon.trackSpan / laps
    private static let barEnd = DuoIcon.barSpan / laps

    /// True while the icon shows the headphone symbol instead of Wi-Fi.
    var isShowingHeadphones: Bool { glimpseSymbol != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(outer)
        layer?.addSublayer(center)
        let path = DuoIcon.arcPath(from: DuoIcon.trackStart, span: Self.laps)
        [track, battery, sweep].forEach { shape in
            shape.frame = NSRect(origin: .zero, size: DuoIcon.size)
            shape.fillColor = nil
            shape.lineWidth = DuoIcon.strokeWidth
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.path = path
            shape.strokeStart = 0
            shape.strokeEnd = Self.trackEnd
            outer.addSublayer(shape)
        }
        battery.strokeEnd = 0
        sweep.strokeEnd = 0
        sweep.opacity = 0
        let diameter = DuoIcon.dotDiameter
        for (index, dot) in dots.enumerated() {
            dot.path = CGPath(ellipseIn: CGRect(x: -diameter/2, y: -diameter/2, width: diameter, height: diameter), transform: nil)
            dot.position = DuoIcon.point(atFraction: DuoIcon.dotFraction(index: index, count: dots.count))
            outer.addSublayer(dot)
        }
        bar.frame = NSRect(origin: .zero, size: DuoIcon.size)
        bar.fillColor = nil
        bar.lineWidth = DuoIcon.dotDiameter
        bar.lineCap = .round
        bar.lineJoin = .round
        bar.path = DuoIcon.arcPath(from: DuoIcon.dotFraction(index: dots.count - 1, count: dots.count), span: Self.laps)
        bar.strokeStart = 0
        bar.strokeEnd = Self.barEnd
        bar.isHidden = true
        outer.addSublayer(bar)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let frame = NSRect(x: bounds.midX-DuoIcon.size.width/2, y: bounds.midY-DuoIcon.size.height/2,
                           width: DuoIcon.size.width, height: DuoIcon.size.height)
        outer.frame = frame; center.frame = frame
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { refreshAppearance() }
    override func viewDidChangeBackingProperties() { refreshAppearance() }
    private func refreshAppearance() {
        guard let status else { return }
        render(status, animated: false)
    }

    func update(_ value: SystemStatus, showVolume: Bool = true) {
        let old = status
        let volumeChanged = showVolume != self.showVolume
        guard old != value || volumeChanged else { return }
        status = value; self.showVolume = showVolume
        if let old, !old.audio.headphoneActive, value.audio.headphoneActive {
            beginGlimpse(value.audio.headphoneSymbol)
        } else if !value.audio.headphoneActive {
            glimpseSymbol = nil
        }
        render(value, animated: old != nil && !reducedMotion)
        if let old, value.shouldAnimate(from: old) { animateTurn() }
        if let old, !old.battery.connectedToPower && value.battery.connectedToPower { animateCharging() }
        if !value.battery.connectedToPower { sweep.removeAllAnimations(); sweep.opacity = 0 }
    }

    /// Shows the headphones in the middle for a moment, then brings Wi-Fi back.
    private func beginGlimpse(_ symbol: String) {
        glimpseSymbol = symbol
        glimpseGeneration += 1
        let generation = glimpseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.headphoneGlimpse) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.glimpseGeneration == generation, self.glimpseSymbol != nil else { return }
                self.glimpseSymbol = nil
                if let status = self.status { self.render(status, animated: !self.reducedMotion) }
            }
        }
    }

    private func render(_ value: SystemStatus, animated: Bool) {
        // Keep the closure trivial: newer Swift toolchains time out type-checking a large inline body.
        effectiveAppearance.performAsCurrentDrawingAppearance { self.renderContents(value, animated: animated) }
    }

    private func renderContents(_ value: SystemStatus, animated: Bool) {
        do {
            let color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
            let green = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.38, alpha: 1)
            let ring = value.battery.lowPowerMode ? NSColor.systemYellow : (value.battery.connectedToPower ? green : color)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            transition(track, "strokeColor", to: ring.withAlphaComponent(0.20).cgColor, animated: animated)
            transition(battery, "strokeColor", to: ring.cgColor, animated: animated)
            transition(battery, "strokeEnd", to: CGFloat(value.battery.percent ?? 0)/100 * Self.trackEnd, animated: animated)
            sweep.strokeColor = ring.blended(withFraction: 0.7, of: .white)?.cgColor
            let muted = value.audio.showsMuteBar
            let level = value.audio.volumeLevel
            for (index, dot) in dots.enumerated() {
                dot.isHidden = !showVolume || muted
                dot.fillColor = color.cgColor
                let lit = level.map { index < $0 } ?? false
                transition(dot, "opacity", to: lit ? Float(1) : Float(0.50), animated: animated)
            }
            bar.isHidden = !showVolume || !muted
            bar.strokeColor = color.cgColor
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(DuoIcon.size.width*scale), pixelsHigh: Int(DuoIcon.size.height*scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = DuoIcon.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            DuoIcon.draw(status: value, showVolume: showVolume, in: NSRect(origin: .zero, size: DuoIcon.size), color: color,
                         components: .center, centerSymbol: glimpseSymbol, centerTint: .controlAccentColor)
            NSGraphicsContext.restoreGraphicsState()
            if animated {
                let fade = CATransition(); fade.type = .fade; fade.duration = 0.24
                center.add(fade, forKey: "state")
            }
            center.contentsScale = scale; center.contents = rep.cgImage
            CATransaction.commit()
        }
    }

    private func transition(_ layer: CALayer, _ key: String, to value: Any, animated: Bool) {
        let model = layer.value(forKeyPath: key)
        let previous = layer.presentation()?.value(forKeyPath: key) ?? model
        layer.setValue(value, forKeyPath: key)
        guard animated else { layer.removeAnimation(forKey: key); return }
        let animation = CABasicAnimation(keyPath: key)
        if let from = model as? CGFloat, let to = value as? CGFloat, key == "strokeEnd" {
            // Additive, so the battery keeps moving smoothly while a turn shifts the same property.
            animation.fromValue = from - to; animation.toValue = 0; animation.isAdditive = true
        } else {
            animation.fromValue = previous; animation.toValue = value
        }
        animation.duration = 0.32
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
    }

    /// Slides the arc, the marks and the mute bar one full lap along the capsule. Every animation is
    /// additive, so battery updates and the charging sweep keep working while the ring is on its way round.
    func animateTurn() {
        guard !reducedMotion else { stopAnimations(); return }
        // Rapid changes and opening the menu join the current turn instead of restarting it.
        guard track.animation(forKey: "turn") == nil else { return }
        let samples = 180
        let times = (0...samples).map { NSNumber(value: Double($0)/Double(samples)) }
        // Radians map onto the outline like a circle; the turn is clockwise, which is the path's direction.
        let offsets = (0...samples).map { IconTurn.angle(at: IconTurn.duration * Double($0)/Double(samples)) / (2 * .pi) }
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let turn = CAKeyframeAnimation(keyPath: keyPath)
            turn.values = values; turn.keyTimes = times
            turn.duration = IconTurn.duration
            turn.calculationMode = .linear
            turn.isAdditive = true
            return turn
        }
        let shifts = offsets.map { -$0 / Self.laps }
        for shape in [track, battery, sweep, bar] {
            shape.add(keyframes("strokeStart", shifts), forKey: "turn")
            shape.add(keyframes("strokeEnd", shifts), forKey: "turnEnd")
        }
        for (index, dot) in dots.enumerated() {
            let fraction = DuoIcon.dotFraction(index: index, count: dots.count)
            let rest = DuoIcon.point(atFraction: fraction)
            let deltas = offsets.map { offset -> NSValue in
                let p = DuoIcon.point(atFraction: fraction + offset)
                return NSValue(point: NSPoint(x: p.x - rest.x, y: p.y - rest.y))
            }
            dot.add(keyframes("position", deltas), forKey: "turn")
        }
    }

    private func animateCharging() {
        guard !reducedMotion else { return }
        let percent = CGFloat(status?.battery.percent ?? 0)/100 * Self.trackEnd
        let tail = DuoIcon.sweepTail / Self.laps
        // Additive with a zero model value, so a turn in progress simply adds its own shift.
        let end = CABasicAnimation(keyPath: "strokeEnd")
        end.fromValue = 0; end.toValue = percent; end.isAdditive = true
        let start = CABasicAnimation(keyPath: "strokeStart")
        start.fromValue = -tail; start.toValue = max(0, percent-tail); start.isAdditive = true
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 0.8, 0]; glow.keyTimes = [0, 0.5, 1]
        let group = CAAnimationGroup(); group.animations = [start, end, glow]; group.duration = 1.05
        sweep.add(group, forKey: "charging")
    }
    func stopAnimations() {
        ([outer, center, track, battery, sweep, bar] + dots).forEach { $0.removeAllAnimations() }
    }
}
