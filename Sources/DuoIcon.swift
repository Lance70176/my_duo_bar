import AppKit

/// Vector renderer shared by the menu item and its live settings icon.
enum DuoIcon {
    static let size = NSSize(width: 32, height: 28)
    static let outerDiameter: CGFloat = 26
    static let strokeWidth: CGFloat = 1.9
    static let dotDiameter: CGFloat = 2.6
    static let radius: CGFloat = (outerDiameter - strokeWidth) / 2
    static let center = NSPoint(x: size.width / 2, y: size.height / 2)

    static func image(status: SystemStatus, layout: DotLayout = DotLayout(), template: Bool = true) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(status: status, layout: layout, in: rect, color: .black)
            return true
        }
        image.isTemplate = template && !status.battery.connectedToPower
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
        let strokeWidth = Self.strokeWidth
        let center = Self.center
        let radius = Self.radius
        // The bottom dots and battery stroke share one circular path.
        let start: CGFloat = 210
        let sweep: CGFloat = -240
        let base = color.usingColorSpace(.deviceRGB) ?? color
        let green = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.38, alpha: 1)
        let ringColor = base.blended(withFraction: frame.charging, of: green) ?? green
        if components == .all {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: frame.ringAngle)
            ctx.translateBy(x: -center.x, y: -center.y)
            func arc(_ fraction: CGFloat, alpha: CGFloat) {
                guard fraction > 0 else { return }
                ringColor.withAlphaComponent(alpha).setStroke()
                let path = NSBezierPath()
                path.lineWidth = strokeWidth
                path.lineCapStyle = .round
                path.appendArc(withCenter: center, radius: radius, startAngle: start,
                               endAngle: start + sweep * fraction, clockwise: true)
                path.stroke()
            }
            arc(1, alpha: 0.20)
            if let percent = frame.percent { arc(percent / 100, alpha: 1) }
            if let phase = frame.chargeSweep, let percent = frame.percent {
                let length = sweep * percent / 100
                let end = start + length * phase
                let path = NSBezierPath(); path.lineWidth = strokeWidth; path.lineCapStyle = .round
                green.blended(withFraction: 0.7, of: .white)?.withAlphaComponent(sin(.pi*phase)*0.8).setStroke()
                path.appendArc(withCenter: center, radius: radius, startAngle: min(start, end+22), endAngle: end, clockwise: true)
                path.stroke()
            }
            ctx.restoreGState()
        }
        if let old = frame.previousWiFi, frame.wifiBlend < 1 {
            ctx.saveGState(); ctx.setAlpha(1-frame.wifiBlend)
            drawWiFi(old, in: NSRect(x: 10.1, y: 11, width: 11.8, height: 8), color: color)
            ctx.restoreGState()
        }
        ctx.saveGState(); ctx.setAlpha(frame.wifiBlend)
        drawWiFi(status.wifi, in: NSRect(x: 10.1, y: 11, width: 11.8, height: 8), color: color)
        ctx.restoreGState()
        // Equal-sized dots: only opacity changes with the state.
        if components == .all {
            for (index, glyph) in dots.enumerated() {
                let active = frame.active[glyph] ?? 0
                let diameter = Self.dotDiameter
                color.withAlphaComponent(0.50 + 0.50*active).setFill()
                let angle = (270 + (CGFloat(index) - CGFloat(dots.count - 1) / 2) * 20) * .pi / 180 + frame.ringAngle
                let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                NSBezierPath(ovalIn: NSRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                           width: diameter, height: diameter)).fill()
            }
        }
        ctx.restoreGState()
    }

    private static func drawWiFi(_ wifi: WiFiState, in rect: NSRect, color: NSColor) {
        guard wifi.associated || wifi.route != .ethernet else {
            drawSymbol("network", in: rect, color: color); return
        }
        let origin = NSPoint(x: rect.midX, y: rect.minY + 0.6)
        let strengths = wifi.signalLevel
        for level in 1...2 {
            let path = NSBezierPath()
            path.lineWidth = 1.45; path.lineCapStyle = .round
            color.withAlphaComponent(wifi.associated && level < strengths ? 1 : 0.25).setStroke()
            path.appendArc(withCenter: origin, radius: CGFloat(level) * 3.2,
                           startAngle: 46, endAngle: 134, clockwise: false)
            path.stroke()
        }
        color.withAlphaComponent(wifi.associated ? 1 : 0.3).setFill()
        let dot = NSBezierPath()
        dot.move(to: NSPoint(x: origin.x - 0.95, y: origin.y + 0.6))
        dot.curve(to: NSPoint(x: origin.x + 0.95, y: origin.y + 0.6),
                  controlPoint1: NSPoint(x: origin.x - 0.8, y: origin.y + 1.4),
                  controlPoint2: NSPoint(x: origin.x + 0.8, y: origin.y + 1.4))
        dot.curve(to: NSPoint(x: origin.x, y: origin.y - 0.6),
                  controlPoint1: NSPoint(x: origin.x + 1.6, y: origin.y + 0.3),
                  controlPoint2: NSPoint(x: origin.x + 0.6, y: origin.y - 0.4))
        dot.curve(to: NSPoint(x: origin.x - 0.95, y: origin.y + 0.6),
                  controlPoint1: NSPoint(x: origin.x - 0.35, y: origin.y - 0.8),
                  controlPoint2: NSPoint(x: origin.x - 1.5, y: origin.y + 0.1))
        dot.close(); dot.fill()
        if !wifi.associated {
            let path = NSBezierPath(); path.lineWidth = 1.25; path.lineCapStyle = .round
            color.setStroke()
            path.move(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 0.5))
            path.line(to: NSPoint(x: rect.maxX - 1.5, y: rect.minY))
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
