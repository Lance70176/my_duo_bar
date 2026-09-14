import AppKit
import QuartzCore

@main
struct IconTests {
    static func check(_ passed: Bool, _ text: String) {
        guard passed else { fputs("FAIL: \(text)\n", stderr); exit(1) }
    }
    static func bitmap(_ status: SystemStatus, frame: IconFrame? = nil) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 280,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        DuoIcon.draw(status: status, presentation: frame, in: NSRect(x: 0, y: 0, width: 320, height: 280), color: .black)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func alpha(_ rep: NSBitmapImageRep, x: Double, y: Double) -> Double {
        Double(rep.colorAt(x: Int(x*10), y: 279-Int(y*10))!.alphaComponent)
    }
    static func main() throws {
        _ = NSApplication.shared
        var state = SystemStatus.preview(); state.battery.percent = 75
        let image = bitmap(state)
        check(alpha(image, x: 5.56, y: 7.98) > 0.9, "75 percent keeps the left end bright")
        check(alpha(image, x: 26.44, y: 7.98) < 0.3, "battery depletion begins at the right end")
        state.battery.percent = 100
        let full = bitmap(state)
        check(alpha(full, x: 26.44, y: 7.98) > 0.9, "full battery fills the right end")
        var inactive = state
        inactive.vpn.names = []; inactive.audio.headphoneNames = []; inactive.audio.muted = false; inactive.focus = .off
        let gray = bitmap(inactive)
        // A point 0.95 pt from the first dot's center must remain inside either state.
        let angle = 240.0 * Double.pi/180
        let x = DuoIcon.center.x+DuoIcon.radius*cos(angle)+0.95, y = DuoIcon.center.y+DuoIcon.radius*sin(angle)
        check(alpha(full, x: x, y: y) > 0.8 && alpha(gray, x: x, y: y) > 0.2,
              "inactive dots retain the active dot radius")
        let dotCenter = NSPoint(x: DuoIcon.center.x+DuoIcon.radius*cos(angle), y: DuoIcon.center.y+DuoIcon.radius*sin(angle))
        let dotHalfWidth = Double(DuoIcon.dotDiameter)/2
        check(alpha(gray, x: dotCenter.x, y: dotCenter.y) >= 0.49, "inactive dots are clearly visible at half opacity")
        check(alpha(full, x: dotCenter.x+dotHalfWidth-0.2, y: dotCenter.y) > 0.75,
              "dots retain their specified diameter")
        check(alpha(full, x: dotCenter.x+dotHalfWidth+0.3, y: dotCenter.y) < 0.1,
              "dot edges stop at the specified diameter")
        var chargingState = state; chargingState.battery.charging = true
        let chargingImage = bitmap(chargingState)
        let green = chargingImage.colorAt(x: 160, y: 19)!.usingColorSpace(.deviceRGB)!
        check(green.greenComponent > green.redComponent + 0.3, "charging ring is visibly green")
        var lowPower = chargingState; lowPower.battery.lowPowerMode = true
        let yellow = bitmap(lowPower).colorAt(x: 160, y: 19)!.usingColorSpace(.deviceRGB)!
        check(yellow.redComponent > 0.8 && yellow.greenComponent > 0.5 && yellow.blueComponent < 0.3,
              "low power mode makes the preview ring yellow even while charging")
        var orbitFrame = IconFrame.steady(state)
        orbitFrame.ringAngle = -.pi/2
        let orbited = bitmap(state, frame: orbitFrame)
        check(alpha(orbited, x: 5.56, y: 20.03) > 0.9, "the first dot follows the same circular orbit as the battery ring")
        var uprightWiFi = true
        for x in 96..<224 {
            for y in 84..<184 {
                if full.colorAt(x: x, y: y) != orbited.colorAt(x: x, y: y) { uprightWiFi = false }
            }
        }
        check(uprightWiFi, "Wi-Fi pixels remain upright while the outer circle turns")
        check(IconTurn.angle(at: 0) == 0, "the turn begins without a jump")
        check(IconTurn.angle(at: 1.07) < -2 * .pi, "the turn includes a small overshoot")
        check(abs(IconTurn.angle(at: IconTurn.duration) + 2 * .pi) < 0.00001, "the turn settles at one complete revolution")
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 36, height: 28),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = StatusIconView(frame: NSRect(x: 0, y: 0, width: 36, height: 28))
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.update(state); view.layoutSubtreeIfNeeded()
        let outer = view.layer!.sublayers![0]
        let center = view.layer!.sublayers![1]
        let batteryLayer = outer.sublayers![1] as! CAShapeLayer
        let sweep = outer.sublayers![2]
        let dotLayers = Array(outer.sublayers!.dropFirst(3))
        check(outer.animationKeys() == nil, "first sample stays still")
        check(dotLayers.count == 4, "the live renderer has all four dots")
        check(abs(batteryLayer.path!.boundingBoxOfPath.width + batteryLayer.lineWidth - 26) < 0.01,
              "the live ring outer diameter is 26 points")
        check(abs(batteryLayer.lineWidth - 2.47) < 0.001, "the live ring stroke is 2.47 points")
        check(2 * (DuoIcon.radius + DuoIcon.dotDiameter/2) < outer.bounds.height,
              "the complete rotating dot envelope fits without clipping")
        for dot in dotLayers {
            let shape = dot as! CAShapeLayer
            check(abs(shape.path!.boundingBox.width - 3.12) < 0.001,
                  "live dots measure 3.12 points")
        }
        view.update(inactive)
        check(dotLayers.allSatisfy { $0.opacity == 0.50 }, "inactive live dots remain visible")
        check(dotLayers[3].opacity == 0.50, "Focus off dims the correct dot")
        var focused = inactive; focused.focus = .active
        view.update(focused)
        check(dotLayers[3].opacity == 1, "Focus on lights the real fourth layer")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(outer.animation(forKey: "turn") is CAKeyframeAnimation, "a status event starts a composited turn")
            check(center.animation(forKey: "turn") == nil, "Wi-Fi stays upright")
            CATransaction.flush()
            let before = outer.animation(forKey: "turn")!.beginTime
            var batteryChange = focused; batteryChange.battery.percent = 99
            view.update(batteryChange); view.animateTurn()
            check(outer.animation(forKey: "turn")!.beginTime == before,
                  "battery updates and clicks do not restart an existing turn")
            view.stopAnimations(); view.animateTurn()
            check(outer.animation(forKey: "turn") != nil, "clicking the menu starts a fresh turn when idle")
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
        check(outer.animationKeys() == nil && center.animationKeys() == nil, "stopping removes all live animations")
        print("PASS: vector rendering, live layer states, menu click, coalesced orbit and charging")
    }
}
