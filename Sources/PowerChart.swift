import AppKit

/// The power chart in the Battery submenu: adapter input and battery charge power over the last two hours,
/// the battery level on its own 0–100% scale, and the adapter's rating as a dashed line. Pointing at the chart
/// shows a crosshair and puts that moment's figures in the legend. Drawn by hand so it stays in the menu's colors.
final class PowerChartView: NSView {
    static let height: CGFloat = 150
    static let span = PowerLogger.chartSpan
    /// Readings further apart than this (sleep, app not running) break the line; macOS refreshes about every 30 seconds.
    static let gap: TimeInterval = 120

    var samples: [PowerSample] = [] { didSet { needsDisplay = true; updateAccessibility() } }
    /// The chart's right edge; the latest sample's time unless set.
    var now: Date?
    /// Where the pointer is, in view coordinates; nil when it is outside the chart.
    var hoverX: CGFloat? { didSet { if hoverX != oldValue { needsDisplay = true } } }
    override var allowsVibrancy: Bool { true }
    override var isFlipped: Bool { false }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static var inputColor: NSColor { .controlAccentColor }
    static var chargeColor: NSColor { .systemOrange }
    static var levelColor: NSColor { .systemGreen }

    /// The plot area inside the view: the legend sits above it and the time labels below.
    var plot: NSRect { NSRect(x: 14, y: 18, width: bounds.width - 28, height: bounds.height - 42) }

    /// The samples in the window, and the top of the watt scale: a quarter above the rating or the highest
    /// reading, rounded up to 10 W, so the rating line stays clear of the scale label.
    func visible() -> (samples: [PowerSample], end: Date, top: Double) {
        let end = now ?? samples.last?.date ?? Date()
        let shown = samples.filter { $0.date >= end.addingTimeInterval(-Self.span) && $0.date <= end }
        let highest = shown.map { max($0.inputWatts, $0.batteryWatts, Double($0.adapterWatts ?? 0)) }.max() ?? 0
        return (shown, end, max(10, (highest * 1.25 / 10).rounded(.up) * 10))
    }

    /// The reading closest in time to a point along the chart, or nil when there is none within a gap of it.
    func sample(atX x: CGFloat) -> PowerSample? {
        let (shown, end, _) = visible()
        let fraction = Double(max(0, min(1, (x - plot.minX) / plot.width)))
        let time = end.addingTimeInterval(-Self.span * (1 - fraction))
        guard let nearest = shown.min(by: { abs($0.date.timeIntervalSince(time)) < abs($1.date.timeIntervalSince(time)) }),
              abs(nearest.date.timeIntervalSince(time)) <= Self.gap else { return nil }
        return nearest
    }

    /// "00:20" in local time.
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let (shown, end, top) = visible()
        let plot = self.plot
        let secondary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let hovered = hoverX.flatMap { sample(atX: $0) }
        let focus = hovered ?? shown.last

        // Legend on top: the latest figures, or those under the pointer.
        var x = plot.minX
        for (color, text) in [(Self.inputColor, L10n.powerInputLegend(focus?.inputWatts)),
                              (Self.chargeColor, L10n.powerBatteryLegend(focus?.batteryWatts)),
                              (Self.levelColor, L10n.powerLevelLegend(focus?.percent))] {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.height - 13, width: 7, height: 7)).fill()
            let label = NSAttributedString(string: text, attributes: secondary)
            label.draw(at: NSPoint(x: x + 10, y: bounds.height - 16))
            x += 10 + label.size().width + 10
        }

        // Frame, the halfway line and the scale labels: watts on the left, the level on the right.
        let faint = NSColor.labelColor.withAlphaComponent(0.12)
        faint.setStroke()
        let frame = NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4)
        frame.lineWidth = 1
        frame.stroke()
        let midLine = NSBezierPath()
        midLine.move(to: NSPoint(x: plot.midX, y: plot.minY)); midLine.line(to: NSPoint(x: plot.midX, y: plot.maxY))
        midLine.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        midLine.stroke()
        NSAttributedString(string: "\(Int(top)) W", attributes: secondary).draw(at: NSPoint(x: plot.minX + 4, y: plot.maxY - 14))
        let full = NSAttributedString(string: "100%", attributes: secondary)
        full.draw(at: NSPoint(x: plot.maxX - full.size().width - 4, y: plot.maxY - 14))

        // Time along the bottom: clock times at the ends and the middle, or the pointer's time while pointing.
        if let hovered, let hoverX {
            let label = NSAttributedString(string: Self.clock(hovered.date), attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                                          .foregroundColor: NSColor.labelColor])
            let left = max(plot.minX, min(plot.maxX - label.size().width, hoverX - label.size().width / 2))
            label.draw(at: NSPoint(x: left, y: 2))
        } else {
            let start = NSAttributedString(string: Self.clock(end.addingTimeInterval(-Self.span)), attributes: secondary)
            let middle = NSAttributedString(string: Self.clock(end.addingTimeInterval(-Self.span / 2)), attributes: secondary)
            let last = NSAttributedString(string: Self.clock(end), attributes: secondary)
            start.draw(at: NSPoint(x: plot.minX, y: 2))
            middle.draw(at: NSPoint(x: plot.midX - middle.size().width / 2, y: 2))
            last.draw(at: NSPoint(x: plot.maxX - last.size().width, y: 2))
        }

        guard !shown.isEmpty else {
            let empty = NSAttributedString(string: L10n.powerChartEmpty, attributes: secondary)
            empty.draw(at: NSPoint(x: plot.midX - empty.size().width / 2, y: plot.midY - empty.size().height / 2))
            return
        }
        func xPosition(_ sample: PowerSample) -> CGFloat {
            plot.minX + plot.width * (1 - end.timeIntervalSince(sample.date) / Self.span)
        }
        func watts(_ sample: PowerSample, _ value: Double) -> NSPoint {
            NSPoint(x: xPosition(sample), y: plot.minY + plot.height * max(0, min(1, value / top)))
        }
        func level(_ sample: PowerSample, _ percent: Int) -> NSPoint {
            NSPoint(x: xPosition(sample), y: plot.minY + plot.height * Double(max(0, min(100, percent))) / 100)
        }
        /// Consecutive readings with no gap between them, for the lines and the level fill.
        var runs: [[PowerSample]] = []
        for sample in shown {
            if let previous = runs.last?.last, sample.date.timeIntervalSince(previous.date) <= Self.gap { runs[runs.count - 1].append(sample) }
            else { runs.append([sample]) }
        }

        // The level first, as a line over a soft fill, so the power lines stay on top.
        let gradient = NSGradient(starting: Self.levelColor.withAlphaComponent(0.28), ending: Self.levelColor.withAlphaComponent(0.02))
        let levelLine = NSBezierPath()
        for run in runs {
            let points = run.compactMap { s in s.percent.map { level(s, $0) } }
            guard let first = points.first, let lastPoint = points.last else { continue }
            let area = NSBezierPath()
            area.move(to: NSPoint(x: first.x, y: plot.minY))
            points.forEach(area.line(to:))
            area.line(to: NSPoint(x: lastPoint.x, y: plot.minY))
            area.close()
            gradient?.draw(in: area, angle: -90)
            levelLine.move(to: first)
            points.dropFirst().forEach(levelLine.line(to:))
        }
        levelLine.lineWidth = 1.6
        levelLine.lineJoinStyle = .round
        Self.levelColor.setStroke()
        levelLine.stroke()

        if let rated = shown.last(where: \.connected)?.adapterWatts {
            let y = plot.minY + plot.height * Double(rated) / top
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.setLineDash([3, 3], count: 2, phase: 0)
            line.lineWidth = 1
            NSColor.secondaryLabelColor.setStroke()
            line.stroke()
            NSAttributedString(string: L10n.powerChartRated(rated), attributes: secondary)
                .draw(at: NSPoint(x: plot.minX + 4, y: max(plot.minY + 1, y - 14)))
        }

        for (color, value) in [(Self.chargeColor, { (s: PowerSample) in max(0, s.batteryWatts) }),
                               (Self.inputColor, { (s: PowerSample) in s.inputWatts })] {
            let path = NSBezierPath()
            for run in runs {
                path.move(to: watts(run[0], value(run[0])))
                run.dropFirst().forEach { path.line(to: watts($0, value($0))) }
            }
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }

        // The crosshair: a vertical line through the reading under the pointer and a dot on each line.
        guard let hovered else { return }
        let lineX = xPosition(hovered)
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: lineX, y: plot.minY)); cross.line(to: NSPoint(x: lineX, y: plot.maxY))
        cross.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        cross.stroke()
        var dots: [(NSColor, NSPoint)] = [(Self.inputColor, watts(hovered, hovered.inputWatts)),
                                          (Self.chargeColor, watts(hovered, max(0, hovered.batteryWatts)))]
        if let percent = hovered.percent { dots.append((Self.levelColor, level(hovered, percent))) }
        for (color, center) in dots {
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
            color.setFill()
            dot.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
    }

    // MARK: Pointer

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Menus track the mouse themselves; activeAlways keeps the events coming inside a menu window.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { point(at: event) }
    override func mouseMoved(with event: NSEvent) { point(at: event) }
    override func mouseExited(with event: NSEvent) { hoverX = nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverX = nil }

    private func point(at event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        hoverX = plot.insetBy(dx: 0, dy: -18).contains(location) ? location.x : nil
    }

    private func updateAccessibility() {
        let last = samples.last
        setAccessibilityLabel([L10n.powerChartTitle, L10n.powerInputLegend(last?.inputWatts),
                               L10n.powerBatteryLegend(last?.batteryWatts), L10n.powerLevelLegend(last?.percent)].joined(separator: ", "))
    }
}
