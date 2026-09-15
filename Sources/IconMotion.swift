import AppKit

struct IconFrame {
    var percent: CGFloat?
    var charging: CGFloat
    var ringAngle: CGFloat = 0
    /// Volume marks lit at the bottom (0...4); nil when the level is unknown.
    var volumeLevel: Int?
    /// The bottom shows one bar instead of the marks.
    var muted = false
    var previousWiFi: WiFiState?
    var wifiBlend: CGFloat = 1
    var chargeSweep: CGFloat?
    var chargePulse: CGFloat = 0

    static func steady(_ status: SystemStatus) -> IconFrame {
        IconFrame(percent: status.battery.percent.map(CGFloat.init), charging: status.battery.connectedToPower ? 1 : 0,
                  volumeLevel: status.audio.volumeLevel, muted: status.audio.showsMuteBar)
    }
}

/// The joined outer circle makes one smooth turn, settles, then rests.
/// Wi-Fi stays upright. A complete turn lets a state change start and end in place.
enum IconTurn {
    static let duration: TimeInterval = 1.43
    static func angle(at elapsed: TimeInterval) -> CGFloat {
        func smootherStep(_ value: Double) -> CGFloat {
            let t = CGFloat(min(1, max(0, value)))
            return t*t*t*(t*(t*6-15)+10)
        }
        // Ease into the turn and settle back by nine degrees.
        let turnTime = duration * (1.06 / 1.43)
        let degrees: CGFloat
        if elapsed < turnTime { degrees = -369 * smootherStep(elapsed / turnTime) }
        else { degrees = -369 + 9 * smootherStep((elapsed-turnTime)/(duration-turnTime)) }
        return degrees * .pi / 180
    }
}
