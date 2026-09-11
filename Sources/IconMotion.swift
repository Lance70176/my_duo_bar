import AppKit

struct IconFrame {
    var percent: CGFloat?
    var charging: CGFloat
    var ringAngle: CGFloat = 0
    var active: [StatusGlyph: CGFloat]
    var previousWiFi: WiFiState?
    var wifiBlend: CGFloat = 1
    var chargeSweep: CGFloat?
    var chargePulse: CGFloat = 0

    static func steady(_ status: SystemStatus) -> IconFrame {
        IconFrame(percent: status.battery.percent.map(CGFloat.init), charging: status.battery.connectedToPower ? 1 : 0,
                  active: Dictionary(uniqueKeysWithValues: StatusGlyph.allCases.map { ($0, $0.isActive(in: status) ? 1 : 0) }))
    }
}

/// The GIF's joined outer circle: one smooth turn, a small overshoot, then rest.
/// Wi-Fi stays upright. A complete turn lets a state change start and end in place.
enum IconTurn {
    static let duration: TimeInterval = 1.20
    static func angle(at elapsed: TimeInterval) -> CGFloat {
        func smootherStep(_ value: Double) -> CGFloat {
            let t = CGFloat(min(1, max(0, value)))
            return t*t*t*(t*(t*6-15)+10)
        }
        // Same timing ratio and 9-degree settling motion as the fusion GIF.
        let turnTime = duration * (1.06 / 1.43)
        let degrees: CGFloat
        if elapsed < turnTime { degrees = -369 * smootherStep(elapsed / turnTime) }
        else { degrees = -369 + 9 * smootherStep((elapsed-turnTime)/(duration-turnTime)) }
        return degrees * .pi / 180
    }
}

/// Finite orbit and state interpolation. No idle animation.
final class IconMotion {
    private(set) var frame = IconFrame.steady(SystemStatus())
    private var previous: SystemStatus?
    private var timer: Timer?
    private var chargeStarted: TimeInterval?
    private var turnStarted: TimeInterval?
    private let chargeDuration: TimeInterval = 1.05
    var onFrame: (() -> Void)?

    func update(_ status: SystemStatus) {
        let target = IconFrame.steady(status)
        guard let old = previous else {
            previous = status; frame = target; onFrame?(); return
        }
        previous = status
        let componentsChanged = status.shouldAnimate(from: old)
        let chargeChanged = status.battery.connectedToPower != old.battery.connectedToPower
        let percentChanged = status.battery.percent != old.battery.percent
        guard componentsChanged || chargeChanged || percentChanged else { return }
        timer?.invalidate()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            chargeStarted = nil; turnStarted = nil
            frame = target; onFrame?(); return
        }
        let from = frame
        let started = ProcessInfo.processInfo.systemUptime
        if let turn = turnStarted, started-turn >= IconTurn.duration { turnStarted = nil }
        if componentsChanged && turnStarted == nil { turnStarted = started }
        if chargeChanged && status.battery.connectedToPower { chargeStarted = started }
        if !status.battery.connectedToPower { chargeStarted = nil }
        // A second battery/network event must not cancel the connection sweep.
        let chargeRemaining = chargeStarted.map { max(0, chargeDuration - (started - $0)) } ?? 0
        let turnRemaining = turnStarted.map { max(0, IconTurn.duration - (started-$0)) } ?? 0
        let duration = max(0.45, turnRemaining, chargeRemaining)
        let timer = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard elapsed < duration, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                self.finish(target); return
            }
            func ease(_ value: Double) -> CGFloat {
                let t = CGFloat(min(1, max(0, value))); return t*t*(3-2*t)
            }
            let blend = ease(elapsed / 0.32)
            var value = target
            if let a = from.percent, let b = target.percent { value.percent = a + (b-a)*blend }
            let colorBlend = ease(elapsed / (target.charging > from.charging ? 0.45 : 0.32))
            value.charging = from.charging + (target.charging-from.charging)*colorBlend
            for glyph in StatusGlyph.allCases {
                let a = from.active[glyph] ?? 0, b = target.active[glyph] ?? 0
                value.active[glyph] = a + (b-a)*blend
            }
            if old.wifi != status.wifi {
                value.previousWiFi = old.wifi; value.wifiBlend = ease(elapsed / 0.24)
            }
            if let turn = self.turnStarted {
                let elapsed = ProcessInfo.processInfo.systemUptime-turn
                if elapsed < IconTurn.duration { value.ringAngle = IconTurn.angle(at: elapsed) }
                else { self.turnStarted = nil }
            }
            if let connected = self.chargeStarted {
                let t = CGFloat((ProcessInfo.processInfo.systemUptime-connected)/self.chargeDuration)
                if t < 1 {
                    value.chargeSweep = t
                    value.chargePulse = pow(sin(.pi*t), 2)
                } else { self.chargeStarted = nil }
            }
            self.frame = value; self.onFrame?()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func finish(_ target: IconFrame) {
        timer?.invalidate(); timer = nil
        chargeStarted = nil; turnStarted = nil
        frame = target; onFrame?()
    }
    func stop() { timer?.invalidate(); timer = nil; turnStarted = nil; chargeStarted = nil }
    deinit { timer?.invalidate() }
}
