import AppKit

/// Vector renderer shared by the menu item and its live settings icon.
///
/// The ring is a capsule that mirrors the menu bar's highlight shape. Everything on the ring is
/// positioned by a fraction of its outline: 0 is the bottom center, fractions grow towards the
/// right side, over the top and back down the left side. The battery arc runs from the bottom-left
/// end of the track clockwise over the top; the dots share the remaining bottom third.
enum DuoIcon {
    /// Fits the 22 pt menu bar with 2 pt spare height.
    static let size = NSSize(width: 32, height: 22)
    static let ringSize = NSSize(width: 28, height: 18)
    static let strokeWidth: CGFloat = 2.0
    static let dotDiameter: CGFloat = 2.5
    static let center = NSPoint(x: size.width / 2, y: size.height / 2)
    /// The track starts at the bottom-left end and covers two thirds of the outline.
    static let trackStart: CGFloat = 5 / 6
    static let trackSpan: CGFloat = 2 / 3
    /// Neighbouring dots sit one eighteenth of the outline apart, as 20° did on the former circle.
    static let dotSpacing: CGFloat = 1 / 18
    /// Length of the charging sweep's bright tail, as a fraction of the outline.
    static let sweepTail: CGFloat = 22 / 360

    /// Stroke centerline of the capsule as a closed polyline with cumulative lengths.
    private static let outline: (points: [CGPoint], lengths: [CGFloat]) = {
        let r = (ringSize.height - strokeWidth) / 2
        let half = (ringSize.width - strokeWidth) / 2 - r
        var points = [CGPoint(x: center.x, y: center.y - r), CGPoint(x: center.x + half, y: center.y - r)]
        for degree in 0...180 {
            let a = (270 + CGFloat(degree)) * .pi / 180
            points.append(CGPoint(x: center.x + half + r * cos(a), y: center.y + r * sin(a)))
        }
        points.append(CGPoint(x: center.x - half, y: center.y + r))
        for degree in 0...180 {
            let a = (90 + CGFloat(degree)) * .pi / 180
            points.append(CGPoint(x: center.x - half + r * cos(a), y: center.y + r * sin(a)))
        }
        points.append(CGPoint(x: center.x, y: center.y - r))
        var lengths: [CGFloat] = [0]
        for index in 1..<points.count {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        return (points, lengths)
    }()
    static var perimeter: CGFloat { outline.lengths.last ?? 0 }

    /// Point on the ring at a fraction of its outline. Fractions wrap, so turns can pass the start.
    static func point(atFraction fraction: CGFloat) -> CGPoint {
        let (points, lengths) = outline
        var wrapped = fraction.truncatingRemainder(dividingBy: 1)
        if wrapped < 0 { wrapped += 1 }
        let target = wrapped * perimeter
        var index = 1
        while index < lengths.count - 1 && lengths[index] < target { index += 1 }
        let a = points[index - 1], b = points[index], segment = lengths[index] - lengths[index - 1]
        let t = segment > 0 ? (target - lengths[index - 1]) / segment : 0
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Open path along the ring, starting at `start` and running clockwise for `span` of the outline.
    static func arcPath(from start: CGFloat, span: CGFloat) -> CGMutablePath {
        let path = CGMutablePath()
        guard span > 0 else { return path }
        let steps = max(2, Int((span * 360).rounded(.up)))
        for step in 0...steps {
            let p = point(atFraction: start - span * CGFloat(step) / CGFloat(steps))
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    /// The battery track, shifted along the outline by `offset` while the ring turns.
    static func trackPath(offset: CGFloat = 0) -> CGMutablePath {
        arcPath(from: trackStart + offset, span: trackSpan)
    }

    /// Outline fraction of a bottom dot, centred on the gap below the track.
    static func dotFraction(index: Int, count: Int, offset: CGFloat = 0) -> CGFloat {
        (CGFloat(index) - CGFloat(count - 1) / 2) * dotSpacing + offset
    }

    /// Where the Wi-Fi glyph sits inside the ring, in icon points.
    static let wifiRect = NSRect(x: 11.75, y: 8.3, width: 8.5, height: 5.8)

    static func image(status: SystemStatus, layout: DotLayout = DotLayout(), template: Bool = true) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(status: status, layout: layout, in: rect, color: .black)
            return true
        }
        image.isTemplate = template && !status.battery.connectedToPower && !status.battery.lowPowerMode
        return image
    }

    enum Components { case all, center }

    static func draw(status: SystemStatus, layout: DotLayout = DotLayout(), presentation: IconFrame? = nil, in rect: NSRect, color: NSColor, components: Components = .all) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let scale = min(rect.width / size.width, rect.height / size.height)
        ctx.translateBy(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2)
        ctx.scaleBy(x: scale, y: scale)
        let dots = layout.visible
        let frame = presentation ?? .steady(status)
        // A turn slides the arc and the dots along the outline; radians map onto the outline like a circle.
        let offset = frame.ringAngle / (2 * .pi)
        let base = color.usingColorSpace(.deviceRGB) ?? color
        let green = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.38, alpha: 1)
        let ringColor = status.battery.lowPowerMode ? NSColor.systemYellow : (base.blended(withFraction: frame.charging, of: green) ?? green)
        if components == .all {
            ctx.setLineWidth(strokeWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            func arc(from start: CGFloat, span: CGFloat, color: NSColor) {
                guard span > 0 else { return }
                ctx.setStrokeColor(color.cgColor)
                ctx.addPath(arcPath(from: start, span: span))
                ctx.strokePath()
            }
            arc(from: trackStart + offset, span: trackSpan, color: ringColor.withAlphaComponent(0.20))
            if let percent = frame.percent { arc(from: trackStart + offset, span: trackSpan * percent / 100, color: ringColor) }
            if let phase = frame.chargeSweep, let percent = frame.percent {
                let head = trackSpan * percent / 100 * phase
                let tail = max(0, head - sweepTail)
                let bright = ringColor.blended(withFraction: 0.7, of: .white)?.withAlphaComponent(sin(.pi * phase) * 0.8) ?? ringColor
                arc(from: trackStart + offset - tail, span: head - tail, color: bright)
            }
        }
        if let old = frame.previousWiFi, frame.wifiBlend < 1 {
            ctx.saveGState(); ctx.setAlpha(1-frame.wifiBlend)
            drawWiFi(old, in: wifiRect, color: color)
            ctx.restoreGState()
        }
        ctx.saveGState(); ctx.setAlpha(frame.wifiBlend)
        drawWiFi(status.wifi, in: wifiRect, color: color)
        ctx.restoreGState()
        // Equal-sized dots: only opacity changes with the state.
        if components == .all {
            for (index, glyph) in dots.enumerated() {
                let active = frame.active[glyph] ?? 0
                let diameter = Self.dotDiameter
                color.withAlphaComponent(0.50 + 0.50*active).setFill()
                let point = point(atFraction: dotFraction(index: index, count: dots.count, offset: offset))
                NSBezierPath(ovalIn: NSRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                           width: diameter, height: diameter)).fill()
            }
        }
        ctx.restoreGState()
    }

    private static func drawWiFi(_ wifi: WiFiState, in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 1.15, y: 1.15)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        guard wifi.associated || wifi.route != .ethernet else {
            drawSymbol("network", in: rect, color: color); return
        }
        // Proportions of the former 11.8 × 8 pt glyph, scaled to the capsule's interior.
        let k = rect.width / 11.8
        let origin = NSPoint(x: rect.midX, y: rect.minY + 0.6 * k)
        let strengths = wifi.signalLevel
        for level in 1...2 {
            let path = NSBezierPath()
            path.lineWidth = 1.45 * k; path.lineCapStyle = .round
            color.withAlphaComponent(wifi.associated && level < strengths ? 1 : 0.25).setStroke()
            path.appendArc(withCenter: origin, radius: CGFloat(level) * 3.2 * k,
                           startAngle: 46, endAngle: 134, clockwise: false)
            path.stroke()
        }
        color.withAlphaComponent(wifi.associated ? 1 : 0.3).setFill()
        let dot = NSBezierPath()
        func p(_ dx: CGFloat, _ dy: CGFloat) -> NSPoint { NSPoint(x: origin.x + dx * k, y: origin.y + dy * k) }
        dot.move(to: p(-0.95, 0.6))
        dot.curve(to: p(0.95, 0.6), controlPoint1: p(-0.8, 1.4), controlPoint2: p(0.8, 1.4))
        dot.curve(to: p(0, -0.6), controlPoint1: p(1.6, 0.3), controlPoint2: p(0.6, -0.4))
        dot.curve(to: p(-0.95, 0.6), controlPoint1: p(-0.35, -0.8), controlPoint2: p(-1.5, 0.1))
        dot.close(); dot.fill()
        if !wifi.associated {
            let path = NSBezierPath(); path.lineWidth = 1.25 * k; path.lineCapStyle = .round
            color.setStroke()
            path.move(to: NSPoint(x: rect.minX + 2 * k, y: rect.maxY - 0.5 * k))
            path.line(to: NSPoint(x: rect.maxX - 1.5 * k, y: rect.minY))
            path.stroke()
        }
    }

    static func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.height, weight: .semibold)) else { return }
        let ratio = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
        let target = NSRect(x: rect.midX - symbol.size.width * ratio / 2,
                            y: rect.midY - symbol.size.height * ratio / 2,
                            width: symbol.size.width * ratio, height: symbol.size.height * ratio)
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            color.setFill(); r.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: target)
    }
}
