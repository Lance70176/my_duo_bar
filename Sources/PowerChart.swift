import AppKit

/// The power chart in the Battery submenu: adapter input and battery charge power over the last two hours,
/// with the adapter's rating as a dashed line. Drawn by hand so it stays in the menu's own colors.
final class PowerChartView: NSView {
    static let height: CGFloat = 112
    static let span = PowerLogger.chartSpan
    /// Readings further apart than this (sleep, app not running) break the line; macOS refreshes about every 30 seconds.
    static let gap: TimeInterval = 120

    var samples: [PowerSample] = [] { didSet { needsDisplay = true; updateAccessibility() } }
    /// The chart's right edge; the latest sample's time unless set.
    var now: Date?
    override var allowsVibrancy: Bool { true }
    override var isFlipped: Bool { false }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static var inputColor: NSColor { .controlAccentColor }
    static var batteryColor: NSColor { .systemGreen }

    /// The samples in the window, and the top of the watt scale: a quarter above the rating or the highest
    /// reading, rounded up to 10 W, so the rating line stays clear of the scale label.
    func visible() -> (samples: [PowerSample], end: Date, top: Double) {
        let end = now ?? samples.last?.date ?? Date()
        let shown = samples.filter { $0.date >= end.addingTimeInterval(-Self.span) && $0.date <= end }
        let highest = shown.map { max($0.inputWatts, $0.batteryWatts, Double($0.adapterWatts ?? 0)) }.max() ?? 0
        return (shown, end, max(10, (highest * 1.25 / 10).rounded(.up) * 10))
    }

    override func draw(_ dirtyRect: NSRect) {
        let (shown, end, top) = visible()
        let small = NSFont.systemFont(ofSize: 10)
        let secondary: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.secondaryLabelColor]
        let plot = NSRect(x: 20, y: 18, width: bounds.width - 34, height: bounds.height - 40)

        // Legend on top: the latest input and battery figures.
        var x = plot.minX
        for (color, text) in [(Self.inputColor, L10n.powerInputLegend(shown.last?.inputWatts)),
                              (Self.batteryColor, L10n.powerBatteryLegend(shown.last?.batteryWatts))] {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.height - 13, width: 7, height: 7)).fill()
            let label = NSAttributedString(string: text, attributes: secondary)
            label.draw(at: NSPoint(x: x + 11, y: bounds.height - 16))
            x += 11 + label.size().width + 14
        }

        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        let frame = NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4)
        frame.lineWidth = 1
        frame.stroke()
        NSAttributedString(string: "\(Int(top)) W", attributes: secondary).draw(at: NSPoint(x: plot.minX + 4, y: plot.maxY - 14))
        NSAttributedString(string: L10n.powerChartHoursAgo(Int(Self.span / 3600)), attributes: secondary).draw(at: NSPoint(x: plot.minX, y: 2))
        // A faint line at the halfway mark, labelled, so the time along a long span is easy to read.
        let midLine = NSBezierPath()
        midLine.move(to: NSPoint(x: plot.midX, y: plot.minY)); midLine.line(to: NSPoint(x: plot.midX, y: plot.maxY))
        midLine.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        midLine.stroke()
        let midLabel = NSAttributedString(string: L10n.powerChartHoursAgo(Int(Self.span / 7200)), attributes: secondary)
        midLabel.draw(at: NSPoint(x: plot.midX - midLabel.size().width / 2, y: 2))
        let nowLabel = NSAttributedString(string: L10n.powerChartNow, attributes: secondary)
        nowLabel.draw(at: NSPoint(x: plot.maxX - nowLabel.size().width, y: 2))

        guard !shown.isEmpty else {
            let empty = NSAttributedString(string: L10n.powerChartEmpty, attributes: secondary)
            empty.draw(at: NSPoint(x: plot.midX - empty.size().width / 2, y: plot.midY - empty.size().height / 2))
            return
        }
        func point(_ sample: PowerSample, _ watts: Double) -> NSPoint {
            let t = 1 - end.timeIntervalSince(sample.date) / Self.span
            return NSPoint(x: plot.minX + plot.width * t, y: plot.minY + plot.height * max(0, min(1, watts / top)))
        }

        if let rated = shown.last(where: \.connected)?.adapterWatts {
            let y = plot.minY + plot.height * Double(rated) / top
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.setLineDash([3, 3], count: 2, phase: 0)
            line.lineWidth = 1
            NSColor.secondaryLabelColor.setStroke()
            line.stroke()
            let label = NSAttributedString(string: L10n.powerChartRated(rated), attributes: secondary)
            label.draw(at: NSPoint(x: plot.maxX - label.size().width - 4, y: max(plot.minY + 1, y - 14)))
        }

        for (color, value) in [(Self.batteryColor, { (s: PowerSample) in max(0, s.batteryWatts) }),
                               (Self.inputColor, { (s: PowerSample) in s.inputWatts })] {
            let path = NSBezierPath()
            var previous: PowerSample?
            for sample in shown {
                if let previous, sample.date.timeIntervalSince(previous.date) <= Self.gap {
                    path.line(to: point(sample, value(sample)))
                } else {
                    path.move(to: point(sample, value(sample)))
                }
                previous = sample
            }
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
    }

    private func updateAccessibility() {
        let last = samples.last
        setAccessibilityLabel([L10n.powerChartTitle, L10n.powerInputLegend(last?.inputWatts),
                               L10n.powerBatteryLegend(last?.batteryWatts)].joined(separator: ", "))
    }
}
