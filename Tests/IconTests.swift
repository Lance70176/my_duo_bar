import AppKit
import QuartzCore

@main
struct IconTests {
    static func check(_ passed: Bool, _ text: String) {
        guard passed else { fputs("FAIL: \(text)\n", stderr); exit(1) }
    }
    static let pixelsWide = Int(DuoIcon.size.width) * 10
    static let pixelsHigh = Int(DuoIcon.size.height) * 10
    static func bitmap(_ status: SystemStatus, frame: IconFrame? = nil, showVolume: Bool = true, centerSymbol: String? = nil) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        DuoIcon.draw(status: status, showVolume: showVolume, presentation: frame, in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh),
                     color: .black, centerSymbol: centerSymbol)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    /// The Wi-Fi glyph's pixels, inside the capsule and above the marks.
    static func sameCenter(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        for x in 105..<215 {
            for y in 74..<140 where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { return false }
        }
        return true
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
        let bottom = DuoIcon.point(atFraction: 0)
        check(abs(leftEnd.x + rightEnd.x - DuoIcon.size.width) < 0.01 && abs(leftEnd.y - rightEnd.y) < 0.01,
              "the track ends mirror each other at the bottom of the capsule")
        check(abs(top.x - DuoIcon.center.x) < 0.01 && top.y > DuoIcon.center.y, "half way round the outline is the top center")
        check(DuoIcon.size.height <= NSStatusBar.system.thickness, "the icon fits the menu bar without clipping")
        var state = SystemStatus.preview(); state.battery.percent = 75
        // Full volume, not muted: every mark at the bottom is lit.
        state.audio.muted = false; state.audio.volume = 100
        let image = bitmap(state)
        check(alpha(image, at: leftEnd) > 0.9, "75 percent keeps the left end bright")
        check(alpha(image, at: rightEnd) < 0.3, "battery depletion begins at the right end")
        state.battery.percent = 100
        let full = bitmap(state)
        check(alpha(full, at: rightEnd) > 0.9, "full battery fills the right end")
        var inactive = state
        inactive.vpn.names = []; inactive.audio.headphoneNames = []; inactive.audio.volume = nil; inactive.focus = .off
        let gray = bitmap(inactive)
        // A point 0.95 pt from the first mark's center must remain inside either state.
        let dotCenter = DuoIcon.point(atFraction: DuoIcon.dotFraction(index: 0, count: 4))
        check(alpha(full, x: dotCenter.x+0.95, y: dotCenter.y) > 0.8 && alpha(gray, x: dotCenter.x+0.95, y: dotCenter.y) > 0.2,
              "unlit marks retain the lit mark radius")
        let dotHalfWidth = Double(DuoIcon.dotDiameter)/2
        check(alpha(gray, at: dotCenter) >= 0.49, "unknown volume keeps every mark visible at half opacity")
        check(alpha(full, x: dotCenter.x+dotHalfWidth-0.2, y: dotCenter.y) > 0.75,
              "marks retain their specified diameter")
        check(alpha(full, x: dotCenter.x+dotHalfWidth+0.3, y: dotCenter.y) < 0.1,
              "mark edges stop at the specified diameter")
        check(dotCenter.y < DuoIcon.center.y - 5 && dotCenter.x < DuoIcon.center.x, "the first mark sits on the bottom-left of the capsule")
        var half = state; half.audio.volume = 50
        let halfImage = bitmap(half)
        let lastCenter = DuoIcon.point(atFraction: DuoIcon.dotFraction(index: 3, count: 4))
        check(alpha(halfImage, at: dotCenter) > 0.9 && alpha(halfImage, at: lastCenter) < 0.6,
              "half volume lights the left marks and dims the right ones")
        var mutedState = state; mutedState.audio.muted = true
        let mutedImage = bitmap(mutedState)
        check(alpha(mutedImage, at: bottom) > 0.9, "mute draws one bar along the bottom")
        check(alpha(full, at: bottom) < 0.1, "the marks leave the very bottom clear")
        check(alpha(mutedImage, at: DuoIcon.point(atFraction: DuoIcon.dotFraction(index: 3, count: 4) + 0.8 * DuoIcon.dotSpacing)) < 0.1
              && alpha(mutedImage, at: dotCenter) > 0.9 && alpha(mutedImage, at: lastCenter) > 0.9,
              "the bar spans the same stretch of outline as the four marks")
        check(sameCenter(full, mutedImage), "mute leaves the Wi-Fi glyph alone")
        check(!sameCenter(full, bitmap(state, centerSymbol: "headphones")), "a center symbol replaces the Wi-Fi glyph")
        let hiddenVolume = bitmap(mutedState, showVolume: false)
        check(alpha(hiddenVolume, at: bottom) < 0.1 && alpha(hiddenVolume, at: dotCenter) < 0.1,
              "hiding the volume leaves the bottom empty")
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
        check(alpha(orbited, at: orbitedDot) > 0.9, "the first mark follows the same capsule track as the battery ring")
        check(alpha(orbited, at: DuoIcon.point(atFraction: 0.75)) < 0.1, "a quarter turn leaves the gap at the left side empty")
        check(sameCenter(full, orbited), "Wi-Fi pixels remain upright while the outer ring turns")
        var mutedOrbit = IconFrame.steady(mutedState); mutedOrbit.ringAngle = -.pi/2
        let barOrbited = bitmap(mutedState, frame: mutedOrbit)
        // A quarter turn clockwise moves the bar from the bottom to the left side, where the ring's gap now is.
        check(alpha(barOrbited, at: DuoIcon.point(atFraction: 0.75)) > 0.9 && alpha(barOrbited, at: DuoIcon.point(atFraction: 0.623)) < 0.1,
              "the mute bar travels with the ring")
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
        let dotLayers = Array(outer.sublayers!.dropFirst(3).prefix(4))
        let barLayer = outer.sublayers![7] as! CAShapeLayer
        check(outer.animationKeys() == nil && trackLayer.animationKeys() == nil, "first sample stays still")
        check(dotLayers.count == 4 && outer.sublayers!.count == 8, "the live renderer has four volume marks and a mute bar")
        let ringBox = batteryLayer.path!.boundingBoxOfPath
        check(abs(ringBox.width + batteryLayer.lineWidth - 28) < 0.01 && abs(ringBox.height + batteryLayer.lineWidth - 18) < 0.01,
              "the live capsule measures 28 by 18 points")
        check(abs(batteryLayer.lineWidth - 2) < 0.001, "the live ring stroke is 2 points")
        check(abs(trackLayer.strokeEnd - 1.0/3.0) < 0.0001 && abs(batteryLayer.strokeEnd - 1.0/3.0) < 0.0001,
              "the track covers two thirds of one lap of the two-lap path")
        check(ringBox.height + batteryLayer.lineWidth + DuoIcon.dotDiameter < outer.bounds.height,
              "the complete travelling mark envelope fits without clipping")
        for (index, dot) in dotLayers.enumerated() {
            let shape = dot as! CAShapeLayer
            check(abs(shape.path!.boundingBox.width - 2.5) < 0.001, "live marks measure 2.5 points")
            let expected = DuoIcon.point(atFraction: DuoIcon.dotFraction(index: index, count: 4))
            check(abs(shape.position.x - expected.x) < 0.001 && abs(shape.position.y - expected.y) < 0.001,
                  "live marks sit where the vector renderer draws them")
        }
        check(dotLayers.allSatisfy { $0.opacity == 1 } && barLayer.isHidden, "full volume lights every live mark")
        check(abs(barLayer.lineWidth - 2.5) < 0.001 && abs(barLayer.strokeEnd - DuoIcon.barSpan / 2) < 0.0001,
              "the live bar is as thick as a mark and spans the marks along the two-lap path")
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
            let turn = trackLayer.animation(forKey: "turn") as? CAKeyframeAnimation
            check(turn != nil && turn!.isAdditive, "a status event starts a composited, additive turn")
            let shifts = turn!.values as! [CGFloat]
            check(abs(shifts.last! - 0.5) < 0.0001 && shifts.max()! > 0.5 && shifts.first! == 0,
                  "the turn slides the arc exactly one lap along the two-lap path with a small overshoot")
            check(dotLayers[0].animation(forKey: "turn") is CAKeyframeAnimation, "the marks travel with the arc")
            check(barLayer.animation(forKey: "turn") is CAKeyframeAnimation, "the mute bar travels with the arc")
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
        check(outer.animationKeys() == nil && center.animationKeys() == nil && trackLayer.animationKeys() == nil && barLayer.animationKeys() == nil,
              "stopping removes all live animations")
        print("PASS: capsule rendering with volume marks, live layer states, menu click, coalesced travelling turn and charging")
    }
}
