import AppKit

@main
struct IconTests {
    static func check(_ passed: Bool, _ text: String) {
        guard passed else { fputs("FAIL: \(text)\n", stderr); exit(1) }
    }
    static func bitmap(_ status: SystemStatus, frame: IconFrame? = nil) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 260,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        DuoIcon.draw(status: status, presentation: frame, in: NSRect(x: 0, y: 0, width: 320, height: 260), color: .black)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func alpha(_ rep: NSBitmapImageRep, x: Double, y: Double) -> Double {
        Double(rep.colorAt(x: Int(x*10), y: 259-Int(y*10))!.alphaComponent)
    }
    static func main() throws {
        _ = NSApplication.shared
        var state = SystemStatus.preview(); state.battery.percent = 75
        let image = bitmap(state)
        check(alpha(image, x: 7.08, y: 7.85) > 0.9, "75 percent keeps the left end bright")
        check(alpha(image, x: 24.92, y: 7.85) < 0.3, "battery depletion begins at the right end")
        state.battery.percent = 100
        let full = bitmap(state)
        check(alpha(full, x: 24.92, y: 7.85) > 0.9, "full battery fills the right end")
        var inactive = state
        inactive.vpn.names = []; inactive.audio.headphoneNames = []; inactive.audio.muted = false; inactive.focus = .off
        let gray = bitmap(inactive)
        // A point 0.95 pt from the first dot's center must remain inside either state.
        let angle = 240.0 * Double.pi/180
        let x = 16+10.3*cos(angle)+0.95, y = 13+10.3*sin(angle)
        check(alpha(full, x: x, y: y) > 0.8 && alpha(gray, x: x, y: y) > 0.2,
              "inactive dots retain the active dot radius")
        let dotCenter = NSPoint(x: 16+10.3*cos(angle), y: 13+10.3*sin(angle))
        let sharedHalfWidth = Double(DuoIcon.strokeWidth)/2
        check(alpha(gray, x: dotCenter.x, y: dotCenter.y) >= 0.49, "inactive dots are clearly visible at half opacity")
        check(alpha(full, x: dotCenter.x+sharedHalfWidth-0.2, y: dotCenter.y) > 0.75,
              "dots use the larger shared ring width")
        check(alpha(full, x: dotCenter.x+sharedHalfWidth+0.3, y: dotCenter.y) < 0.1,
              "dot diameter stays equal to the ring width")
        var chargingState = state; chargingState.battery.charging = true
        let chargingImage = bitmap(chargingState)
        let green = chargingImage.colorAt(x: 160, y: 26)!.usingColorSpace(.deviceRGB)!
        check(green.greenComponent > green.redComponent + 0.3, "charging ring is visibly green")
        var orbitFrame = IconFrame.steady(state)
        orbitFrame.ringAngle = -.pi/2
        let orbited = bitmap(state, frame: orbitFrame)
        check(alpha(orbited, x: 7.08, y: 18.15) > 0.9, "the first dot follows the same circular orbit as the battery ring")
        var uprightWiFi = true
        for x in 112..<209 {
            for y in 82..<169 {
                if full.colorAt(x: x, y: y) != orbited.colorAt(x: x, y: y) { uprightWiFi = false }
            }
        }
        check(uprightWiFi, "Wi-Fi pixels remain upright while the outer circle turns")
        check(IconTurn.angle(at: 0) == 0, "the turn begins without a jump")
        check(IconTurn.angle(at: 0.9) < -2 * .pi, "the GIF curve includes a small overshoot")
        check(abs(IconTurn.angle(at: IconTurn.duration) + 2 * .pi) < 0.00001, "the turn settles at one complete revolution")
        let motion = IconMotion()
        var frames = 0
        motion.onFrame = { frames += 1 }
        motion.update(state)
        var changed = state; changed.audio.muted = false
        motion.update(changed)
        RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(motion.frame.ringAngle < 0, "the outer circle turns clockwise")
            let before = motion.frame.ringAngle
            changed.battery.percent = 99
            motion.update(changed)
            check(motion.frame.ringAngle == before, "a battery update does not jump or restart the orbit")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.22))
        check(motion.frame.ringAngle == 0, "the outer circle returns to its original orientation")
        check(motion.frame.active[.mute] == 0, "changed dot reaches its new opacity")
        chargingState = changed; chargingState.battery.charging = true
        motion.update(chargingState)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(motion.frame.charging > 0 && motion.frame.charging < 1, "charging color transitions gradually")
            check(motion.frame.chargeSweep != nil, "connecting power produces one short sweep")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.05))
        check(motion.frame.charging == 1 && motion.frame.chargeSweep == nil && motion.frame.chargePulse == 0,
              "charging settles to a static green ring")
        // Actual power connection often arrives before IsCharging, followed by new readings.
        motion.update(changed)
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        var connected = changed
        connected.battery.externalPower = true
        connected.battery.charging = false
        motion.update(connected)
        RunLoop.current.run(until: Date().addingTimeInterval(0.14))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(motion.frame.chargeSweep != nil, "AC connection animates before IsCharging becomes true")
        }
        connected.battery.percent = 98
        connected.wifi.ssid = "Changed during charging"
        motion.update(connected)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check((motion.frame.chargeSweep ?? 0) > 0.18, "follow-up battery and Wi-Fi events preserve the connection animation")
        }
        connected.battery.charging = true
        motion.update(connected)
        RunLoop.current.run(until: Date().addingTimeInterval(1.25))
        check(motion.frame.charging == 1 && motion.frame.chargeSweep == nil, "connected power stays green after the transition")
        connected.battery.charging = false
        motion.update(connected)
        check(motion.frame.charging == 1, "charging pause while on AC keeps the ring green")
        var disconnected = connected
        disconnected.battery.externalPower = false
        disconnected.battery.charging = false
        motion.update(disconnected)
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        check(motion.frame.charging == 0, "disconnecting power returns to the normal ring")
        let finishedCount = frames
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        check(frames == finishedCount, "no idle animation frames remain")
        print("PASS: battery direction, equal dots, joined orbit and charging transitions (\(frames) frames)")
    }
}
