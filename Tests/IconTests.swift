import AppKit
import QuartzCore

@main
struct IconTests {
    static func check(_ passed: Bool, _ text: String) {
        guard passed else { fputs("FAIL: \(text)\n", stderr); exit(1) }
    }
    static let pixelsWide = Int(DuoIcon.size.width) * 10
    static let pixelsHigh = Int(DuoIcon.size.height) * 10
    static func bitmap(_ status: SystemStatus, frame: IconFrame? = nil) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        DuoIcon.draw(status: status, presentation: frame, in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh), color: .black)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func alpha(_ rep: NSBitmapImageRep, x: Double, y: Double) -> Double {
        Double(rep.colorAt(x: Int(x*10), y: pixelsHigh-1-Int(y*10))!.alphaComponent)
    }
    static func alpha(_ rep: NSBitmapImageRep, at point: CGPoint) -> Double { alpha(rep, x: point.x, y: point.y) }
    static func main() throws {
        _ = NSApplication.shared
        let leftEnd = DuoIcon.point(atFraction: DuoIcon.trackStart)
        let rightEnd = DuoIcon.point(atFraction: DuoIcon.trackStart - DuoIcon.trackSpan)
        let top = DuoIcon.point(atFraction: 0.5)
        check(abs(leftEnd.x + rightEnd.x - DuoIcon.size.width) < 0.01 && abs(leftEnd.y - rightEnd.y) < 0.01,
              "the track ends mirror each other at the bottom of the capsule")
        check(abs(top.x - DuoIcon.center.x) < 0.01 && top.y > DuoIcon.center.y, "half way round the outline is the top center")
        check(DuoIcon.size.height <= NSStatusBar.system.thickness, "the icon fits the menu bar without clipping")
        var state = SystemStatus.preview(); state.battery.percent = 75
        let image = bitmap(state)
        check(alpha(image, at: leftEnd) > 0.9, "75 percent keeps the left end bright")
        check(alpha(image, at: rightEnd) < 0.3, "battery depletion begins at the right end")
        state.battery.percent = 100
        let full = bitmap(state)
        check(alpha(full, at: rightEnd) > 0.9, "full battery fills the right end")
        var inactive = state
        inactive.vpn.names = []; inactive.audio.headphoneNames = []; inactive.audio.muted = false; inactive.focus = .off
        let gray = bitmap(inactive)
        // A point 0.95 pt from the first dot's center must remain inside either state.
        let dotCenter = DuoIcon.point(atFraction: DuoIcon.dotFraction(index: 0, count: 4))
        check(alpha(full, x: dotCenter.x+0.95, y: dotCenter.y) > 0.8 && alpha(gray, x: dotCenter.x+0.95, y: dotCenter.y) > 0.2,
              "inactive dots retain the active dot radius")
        let dotHalfWidth = Double(DuoIcon.dotDiameter)/2
        check(alpha(gray, at: dotCenter) >= 0.49, "inactive dots are clearly visible at half opacity")
        check(alpha(full, x: dotCenter.x+dotHalfWidth-0.2, y: dotCenter.y) > 0.75,
              "dots retain their specified diameter")
        check(alpha(full, x: dotCenter.x+dotHalfWidth+0.3, y: dotCenter.y) < 0.1,
              "dot edges stop at the specified diameter")
        check(dotCenter.y < DuoIcon.center.y - 5 && dotCenter.x < DuoIcon.center.x, "the first dot sits on the bottom-left of the capsule")
        var chargingState = state; chargingState.battery.charging = true
        let chargingImage = bitmap(chargingState)
        let green = chargingImage.colorAt(x: Int(top.x*10), y: pixelsHigh-1-Int(top.y*10))!.usingColorSpace(.deviceRGB)!
        check(green.greenComponent > green.redComponent + 0.3, "charging ring is visibly green")
        var lowPower = chargingState; lowPower.battery.lowPowerMode = true
        let yellow = bitmap(lowPower).colorAt(x: Int(top.x*10), y: pixelsHigh-1-Int(top.y*10))!.usingColorSpace(.deviceRGB)!
        check(yellow.redComponent > 0.8 && yellow.greenComponent > 0.5 && yellow.blueComponent < 0.3,
              "low power mode makes the preview ring yellow even while charging")
        var orbitFrame = IconFrame.steady(state)
        orbitFrame.ringAngle = -.pi/2
        let orbited = bitmap(state, frame: orbitFrame)
        let orbitedDot = DuoIcon.point(atFraction: DuoIcon.dotFraction(index: 0, count: 4) - 0.25)
        check(alpha(orbited, at: orbitedDot) > 0.9, "the first dot follows the same capsule track as the battery ring")
        check(alpha(orbited, at: DuoIcon.point(atFraction: 0.75)) < 0.1, "a quarter turn leaves the gap at the left side empty")
        var uprightWiFi = true
        for x in 105..<215 {
            for y in 74..<140 {
                if full.colorAt(x: x, y: y) != orbited.colorAt(x: x, y: y) { uprightWiFi = false }
            }
        }
        check(uprightWiFi, "Wi-Fi pixels remain upright while the outer ring turns")
        check(IconTurn.angle(at: 0) == 0, "the turn begins without a jump")
        check(IconTurn.angle(at: 1.07) < -2 * .pi, "the turn includes a small overshoot")
        check(abs(IconTurn.angle(at: IconTurn.duration) + 2 * .pi) < 0.00001, "the turn settles at one complete revolution")
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 36, height: 22),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = StatusIconView(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.update(state); view.layoutSubtreeIfNeeded()
        let outer = view.layer!.sublayers![0]
        let center = view.layer!.sublayers![1]
        let trackLayer = outer.sublayers![0] as! CAShapeLayer
        let batteryLayer = outer.sublayers![1] as! CAShapeLayer
        let sweep = outer.sublayers![2]
        let dotLayers = Array(outer.sublayers!.dropFirst(3))
        check(outer.animationKeys() == nil && trackLayer.animationKeys() == nil, "first sample stays still")
        check(dotLayers.count == 4, "the live renderer has all four dots")
        let ringBox = batteryLayer.path!.boundingBoxOfPath
        check(abs(ringBox.width + batteryLayer.lineWidth - 28) < 0.01 && abs(ringBox.height + batteryLayer.lineWidth - 18) < 0.01,
              "the live capsule measures 28 by 18 points")
        check(abs(batteryLayer.lineWidth - 2) < 0.001, "the live ring stroke is 2 points")
        check(abs(trackLayer.strokeEnd - 1.0/3.0) < 0.0001 && abs(batteryLayer.strokeEnd - 1.0/3.0) < 0.0001,
              "the track covers two thirds of one lap of the two-lap path")
        check(ringBox.height + batteryLayer.lineWidth + DuoIcon.dotDiameter < outer.bounds.height,
              "the complete travelling dot envelope fits without clipping")
        for (index, dot) in dotLayers.enumerated() {
            let shape = dot as! CAShapeLayer
            check(abs(shape.path!.boundingBox.width - 2.5) < 0.001, "live dots measure 2.5 points")
            let expected = DuoIcon.point(atFraction: DuoIcon.dotFraction(index: index, count: 4))
            check(abs(shape.position.x - expected.x) < 0.001 && abs(shape.position.y - expected.y) < 0.001,
                  "live dots sit where the vector renderer draws them")
        }
        view.update(inactive)
        check(dotLayers.allSatisfy { $0.opacity == 0.50 }, "inactive live dots remain visible")
        check(dotLayers[3].opacity == 0.50, "Focus off dims the correct dot")
        var focused = inactive; focused.focus = .active
        view.update(focused)
        check(dotLayers[3].opacity == 1, "Focus on lights the real fourth layer")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let turn = trackLayer.animation(forKey: "turn") as? CAKeyframeAnimation
            check(turn != nil && turn!.isAdditive, "a status event starts a composited, additive turn")
            let shifts = turn!.values as! [CGFloat]
            check(abs(shifts.last! - 0.5) < 0.0001 && shifts.max()! > 0.5 && shifts.first! == 0,
                  "the turn slides the arc exactly one lap along the two-lap path with a small overshoot")
            check(dotLayers[0].animation(forKey: "turn") is CAKeyframeAnimation, "the dots travel with the arc")
            check(outer.animation(forKey: "turn") == nil, "the capsule itself never rotates")
            check(center.animation(forKey: "turn") == nil, "Wi-Fi stays upright")
            CATransaction.flush()
            let before = trackLayer.animation(forKey: "turn")!.beginTime
            var batteryChange = focused; batteryChange.battery.percent = 99
            view.update(batteryChange); view.animateTurn()
            check(trackLayer.animation(forKey: "turn")!.beginTime == before,
                  "battery updates and clicks do not restart an existing turn")
            let level = batteryLayer.animation(forKey: "strokeEnd") as? CABasicAnimation
            check(level != nil && level!.isAdditive, "battery changes animate additively so they survive a turn")
            view.stopAnimations(); view.animateTurn()
            check(trackLayer.animation(forKey: "turn") != nil, "clicking the menu starts a fresh turn when idle")
        }
        var powered = focused; powered.battery.externalPower = true; powered.battery.charging = false
        view.update(powered)
        let ringColor = NSColor(cgColor: batteryLayer.strokeColor!)!.usingColorSpace(.deviceRGB)!
        check(ringColor.greenComponent > ringColor.redComponent + 0.3, "AC power colors the live ring green before charging starts")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(sweep.animation(forKey: "charging") != nil, "connecting power adds a short sweep")
        }
        powered.battery.lowPowerMode = true; view.update(powered)
        let lowPowerRing = NSColor(cgColor: batteryLayer.strokeColor!)!.usingColorSpace(.deviceRGB)!
        check(lowPowerRing.redComponent > 0.8 && lowPowerRing.greenComponent > 0.5 && lowPowerRing.blueComponent < 0.3,
              "low power yellow overrides AC green in the live menu bar layer")
        powered.battery.lowPowerMode = false; view.update(powered)
        let restoredGreen = NSColor(cgColor: batteryLayer.strokeColor!)!.usingColorSpace(.deviceRGB)!
        check(restoredGreen.greenComponent > restoredGreen.redComponent + 0.3,
              "leaving low power mode restores AC green")
        powered.battery.charging = true; view.update(powered)
        powered.battery.externalPower = false; powered.battery.charging = false; view.update(powered)
        check(sweep.animation(forKey: "charging") == nil, "unplugging cancels the charging sweep")
        view.stopAnimations()
        check(outer.animationKeys() == nil && center.animationKeys() == nil && trackLayer.animationKeys() == nil,
              "stopping removes all live animations")
        print("PASS: capsule rendering, live layer states, menu click, coalesced travelling turn and charging")
    }
}
