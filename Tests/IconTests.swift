import AppKit
import QuartzCore

@main
struct IconTests {
    static func check(_ passed: Bool, _ text: String) {
        guard passed else { fputs("FAIL: \(text)\n", stderr); exit(1) }
    }
    static func bitmap(_ status: SystemStatus, frame: IconFrame? = nil, centerSymbol: String? = nil) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 280,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        DuoIcon.draw(status: status, presentation: frame, in: NSRect(x: 0, y: 0, width: 320, height: 280), color: .black,
                     centerSymbol: centerSymbol)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func sameCenter(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        for x in 96..<224 {
            for y in 84..<184 where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { return false }
        }
        return true
    }
    static func alpha(_ rep: NSBitmapImageRep, x: Double, y: Double) -> Double {
        Double(rep.colorAt(x: Int(x*10), y: 279-Int(y*10))!.alphaComponent)
    }
    static func main() throws {
        _ = NSApplication.shared
        var state = SystemStatus.preview(); state.battery.percent = 75
        // Full volume, not muted: every mark at the bottom is lit.
        state.audio.muted = false; state.audio.volume = 100
        let image = bitmap(state)
        check(alpha(image, x: 5.56, y: 7.98) > 0.9, "75 percent keeps the left end bright")
        check(alpha(image, x: 26.44, y: 7.98) < 0.3, "battery depletion begins at the right end")
        state.battery.percent = 100
        let full = bitmap(state)
        check(alpha(full, x: 26.44, y: 7.98) > 0.9, "full battery fills the right end")
        var inactive = state
        inactive.vpn.names = []; inactive.audio.headphoneNames = []; inactive.audio.volume = nil; inactive.focus = .off
        let gray = bitmap(inactive)
        // A point 0.95 pt from the first mark's center must remain inside either state.
        let angle = CGFloat(240.0 * Double.pi / 180)
        let x = DuoIcon.center.x+DuoIcon.radius*cos(angle)+0.95, y = DuoIcon.center.y+DuoIcon.radius*sin(angle)
        check(alpha(full, x: x, y: y) > 0.8 && alpha(gray, x: x, y: y) > 0.2,
              "unlit marks retain the lit mark radius")
        let dotCenter = NSPoint(x: DuoIcon.center.x+DuoIcon.radius*cos(angle), y: DuoIcon.center.y+DuoIcon.radius*sin(angle))
        let dotHalfWidth = Double(DuoIcon.dotDiameter)/2
        check(alpha(gray, x: dotCenter.x, y: dotCenter.y) >= 0.49, "unknown volume keeps every mark visible at half opacity")
        check(alpha(full, x: dotCenter.x+dotHalfWidth-0.2, y: dotCenter.y) > 0.75,
              "marks retain their specified diameter")
        check(alpha(full, x: dotCenter.x+dotHalfWidth+0.3, y: dotCenter.y) < 0.1,
              "mark edges stop at the specified diameter")
        var half = state; half.audio.volume = 50
        let halfImage = bitmap(half)
        let lastAngle = CGFloat(300.0 * Double.pi / 180)
        let lastCenter = NSPoint(x: DuoIcon.center.x+DuoIcon.radius*cos(lastAngle), y: DuoIcon.center.y+DuoIcon.radius*sin(lastAngle))
        check(alpha(halfImage, x: dotCenter.x, y: dotCenter.y) > 0.9 && alpha(halfImage, x: lastCenter.x, y: lastCenter.y) < 0.6,
              "half volume lights the left marks and dims the right ones")
        var mutedState = state; mutedState.audio.muted = true
        let mutedImage = bitmap(mutedState)
        let bottom = NSPoint(x: DuoIcon.center.x, y: DuoIcon.center.y - DuoIcon.radius)
        check(alpha(mutedImage, x: bottom.x, y: bottom.y) > 0.9, "mute draws one bar across the bottom")
        check(alpha(full, x: bottom.x, y: bottom.y) < 0.1, "the marks leave the very bottom clear")
        check(alpha(mutedImage, x: bottom.x + DuoIcon.barHalfLength + 0.4, y: bottom.y) < 0.1
              && alpha(mutedImage, x: bottom.x - DuoIcon.barHalfLength + 0.4, y: bottom.y) > 0.5,
              "the bar spans the same width as the four marks")
        check(sameCenter(full, mutedImage), "mute leaves the Wi-Fi glyph alone")
        check(!sameCenter(full, bitmap(state, centerSymbol: "headphones")), "a center symbol replaces the Wi-Fi glyph")
        let hiddenVolume = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 280, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: hiddenVolume)
        DuoIcon.draw(status: mutedState, showVolume: false, in: NSRect(x: 0, y: 0, width: 320, height: 280), color: .black)
        NSGraphicsContext.restoreGraphicsState()
        check(alpha(hiddenVolume, x: bottom.x, y: bottom.y) < 0.1 && alpha(hiddenVolume, x: dotCenter.x, y: dotCenter.y) < 0.1,
              "hiding the volume leaves the bottom empty")
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
        check(alpha(orbited, x: 5.56, y: 20.03) > 0.9, "the first mark follows the same circular orbit as the battery ring")
        check(sameCenter(full, orbited), "Wi-Fi pixels remain upright while the outer circle turns")
        var mutedOrbit = IconFrame.steady(mutedState); mutedOrbit.ringAngle = -.pi/2
        let barOrbited = bitmap(mutedState, frame: mutedOrbit)
        // A quarter turn clockwise moves the bar from the bottom to the left side, where the ring's gap now is.
        check(alpha(barOrbited, x: DuoIcon.center.x - DuoIcon.radius, y: DuoIcon.center.y) > 0.9
              && alpha(mutedImage, x: DuoIcon.center.x - DuoIcon.radius, y: DuoIcon.center.y) > 0.9
              && alpha(barOrbited, x: DuoIcon.center.x - DuoIcon.radius, y: DuoIcon.center.y - DuoIcon.barHalfLength - 0.5) < 0.1,
              "the mute bar turns with the ring")
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
        let dotLayers = Array(outer.sublayers!.dropFirst(3).prefix(4))
        let barLayer = outer.sublayers![7] as! CAShapeLayer
        check(outer.animationKeys() == nil, "first sample stays still")
        check(dotLayers.count == 4 && outer.sublayers!.count == 8, "the live renderer has four volume marks and a mute bar")
        check(abs(batteryLayer.path!.boundingBoxOfPath.width + batteryLayer.lineWidth - 26) < 0.01,
              "the live ring outer diameter is 26 points")
        check(abs(batteryLayer.lineWidth - 2.47) < 0.001, "the live ring stroke is 2.47 points")
        check(2 * (DuoIcon.radius + DuoIcon.dotDiameter/2) < outer.bounds.height,
              "the complete rotating dot envelope fits without clipping")
        for dot in dotLayers {
            let shape = dot as! CAShapeLayer
            check(abs(shape.path!.boundingBox.width - 3.12) < 0.001,
                  "live marks measure 3.12 points")
        }
        check(dotLayers.allSatisfy { $0.opacity == 1 } && barLayer.isHidden, "full volume lights every live mark")
        check(abs(barLayer.lineWidth - 3.12) < 0.001 && abs(barLayer.path!.boundingBox.width - (2 * DuoIcon.barHalfLength - 3.12)) < 0.001,
              "the live bar is as thick as a mark and spans the marks")
        view.update(inactive)
        check(dotLayers.allSatisfy { $0.opacity == 0.50 }, "unknown volume keeps the live marks visible at half opacity")
        view.update(half)
        check(dotLayers.map(\.opacity) == [1, 1, 0.5, 0.5], "half volume lights the first two live marks")
        var mutedLive = half; mutedLive.audio.muted = true
        view.update(mutedLive)
        check(!barLayer.isHidden && dotLayers.allSatisfy(\.isHidden), "mute swaps the live marks for the bar")
        view.update(half)
        check(barLayer.isHidden && dotLayers.allSatisfy { !$0.isHidden }, "unmuting brings the marks back")
        view.update(half, showVolume: false)
        check(barLayer.isHidden && dotLayers.allSatisfy(\.isHidden), "the volume can be hidden from the live icon")
        view.update(mutedLive, showVolume: false)
        check(barLayer.isHidden, "a hidden volume hides the bar too")
        view.update(inactive, showVolume: true)
        var focused = inactive; focused.focus = .active
        view.update(focused)
        check(!view.isShowingHeadphones, "Wi-Fi is shown while no headphones are connected")
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
        var connected = focused; connected.audio.headphoneNames = ["AirPods Pro"]
        view.update(connected)
        check(view.isShowingHeadphones, "connecting headphones shows them in the middle of the icon")
        RunLoop.main.run(until: Date().addingTimeInterval(StatusIconView.headphoneGlimpse + 0.4))
        check(!view.isShowingHeadphones, "the headphones give way to Wi-Fi again")
        view.update(focused); view.update(connected)
        check(view.isShowingHeadphones, "reconnecting shows the headphones again")
        view.update(focused)
        check(!view.isShowingHeadphones, "disconnecting ends the glimpse at once")
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
