import Foundation

enum FocusState: Equatable {
    case off
    case active
    case unavailable(String)
    var isActive: Bool { self == .active }
    var title: String {
        switch self {
        case .off: return L10n.off
        case .active: return L10n.on
        case .unavailable: return L10n.notShared
        }
    }
    var symbol: String { isActive ? "moon.fill" : "moon" }
    static func shared(_ value: Bool?) -> FocusState {
        guard let value else { return .unavailable(L10n.focusNotSharedYet) }
        return value ? .active : .off
    }
}

struct BatteryState: Equatable {
    var present = false
    var percent: Int?
    var charging = false
    var externalPower = false
    var minutesRemaining: Int?
    var lowPowerMode = false
    /// The system charge limit in effect (System Settings → Battery), or nil when it is off or unavailable.
    var chargeLimit: Int?
    // AC can be connected before the battery starts charging, or while charging is paused.
    var connectedToPower: Bool { present && (externalPower || charging) }
    var title: String { percent.map { "\($0)%" } ?? (present ? L10n.reading : L10n.externalPower) }
    var detail: String {
        if !present { return L10n.noInternalBattery }
        if charging { return chargeLimit.map(L10n.chargingToLimit) ?? L10n.charging }
        if externalPower {
            if percent == 100 { return L10n.fullyCharged }
            if let chargeLimit, let percent, percent >= chargeLimit { return L10n.chargedToLimit(chargeLimit) }
            return L10n.pluggedInNotCharging
        }
        if let minutesRemaining, minutesRemaining > 0 {
            return L10n.onBattery(hours: minutesRemaining / 60, minutes: minutesRemaining % 60)
        }
        return L10n.onBattery
    }
}

enum NetworkLink: String { case wifi, ethernet, other, offline, unknown }
struct WiFiState: Equatable {
    var available = false
    var powered = false
    var associated = false
    var ssid: String?
    var rssi: Int?
    var route: NetworkLink = .unknown
    var title: String {
        if associated { return ssid ?? L10n.wifiConnected }
        if route == .ethernet { return L10n.ethernetConnected }
        if !available { return L10n.noWiFiInterface }
        return powered ? L10n.wifiNotConnected : L10n.wifiOff
    }
    var detail: String {
        if associated {
            let quality = signalQuality
            return (ssid == nil ? L10n.networkNameHidden : "") + quality
        }
        if route == .ethernet { return L10n.usingWiredNetwork }
        return route == .offline ? L10n.noNetworkPath : L10n.openWiFiSettingsHint
    }
    var signalLevel: Int {
        guard associated else { return 0 }
        return rssi.map { $0 >= -60 ? 3 : ($0 >= -72 ? 2 : 1) } ?? 3
    }
    var signalQuality: String {
        guard associated else { return powered ? L10n.notConnected : L10n.turnedOff }
        guard let rssi else { return L10n.connected }
        if rssi >= -60 { return L10n.signalStrong }
        if rssi >= -72 { return L10n.signalFair }
        return L10n.signalWeak
    }
    var symbol: String {
        if associated { return "wifi" }
        if route == .ethernet { return "network" }
        return powered ? "wifi.exclamationmark" : "wifi.slash"
    }
}

struct VPNState: Equatable {
    var names: [String] = []
    var available = true
    var hasUnidentifiedTunnel = false
    var routedTunnel = false
    var systemProxy = false
    var active: Bool { !names.isEmpty || routedTunnel || systemProxy }
    var title: String {
        if !names.isEmpty { return names.joined(separator: L10n.listSeparator) }
        if routedTunnel { return L10n.connected }
        if systemProxy { return L10n.systemProxyOn }
        if !available { return L10n.unavailable }
        if hasUnidentifiedTunnel { return L10n.unidentifiedTunnel }
        return L10n.notConnected
    }
}

struct AudioState: Equatable {
    var outputName = L10n.soundOutputUnavailable
    var headphoneNames: [String] = []
    var muted: Bool?
    var volume: Int?
    var headphoneActive: Bool { !headphoneNames.isEmpty }
    var headphoneTitle: String { headphoneActive ? headphoneNames.joined(separator: L10n.listSeparator) : L10n.notConnected }
    var soundTitle: String {
        if muted == true { return L10n.muted }
        if let volume { return "\(volume)%" }
        return muted == false ? L10n.notMuted : L10n.noVolumeInfo
    }
}

enum StatusGlyph: String, CaseIterable {
    case vpn, headphones, mute, focus
    var title: String {
        switch self {
        case .vpn: return "VPN"
        case .headphones: return L10n.headphones
        case .mute: return L10n.mute
        case .focus: return L10n.focus
        }
    }
    var symbol: String {
        switch self {
        case .vpn: return "key.horizontal"
        case .headphones: return "headphones"
        case .mute: return "speaker.slash.fill"
        case .focus: return "moon.fill"
        }
    }
    func isActive(in status: SystemStatus) -> Bool {
        switch self {
        case .vpn: return status.vpn.active
        case .headphones: return status.audio.headphoneActive
        case .mute: return status.audio.muted == true
        case .focus: return status.focus.isActive
        }
    }
    var label: String {
        switch self {
        case .vpn: return L10n.vpnConnected
        case .headphones: return L10n.headphonesConnected
        case .mute: return L10n.muted
        case .focus: return L10n.focusOn
        }
    }
}

struct SystemStatus: Equatable {
    var battery = BatteryState()
    var wifi = WiFiState()
    var vpn = VPNState()
    var audio = AudioState()
    var focus: FocusState = .unavailable(L10n.focusNeedsReading)
    var glyphs: [StatusGlyph] {
        var items: [StatusGlyph] = []
        if vpn.active { items.append(.vpn) }
        if audio.headphoneActive { items.append(.headphones) }
        if audio.muted == true { items.append(.mute) }
        if focus.isActive { items.append(.focus) }
        return items
    }
    var accessibilitySummary: String {
        (["MyDuoBar", L10n.batteryLevel(battery.title), wifi.title] + glyphs.map(\.label)).joined(separator: L10n.summarySeparator)
    }
    static func preview() -> SystemStatus {
        var s = SystemStatus()
        s.battery = BatteryState(present: true, percent: 87, charging: false, externalPower: false, minutesRemaining: nil)
        s.wifi = WiFiState(available: true, powered: true, associated: true, ssid: "Home Wi-Fi", rssi: -48, route: .wifi)
        s.vpn.names = [L10n.personalVPN]
        s.audio = AudioState(outputName: "AirPods Pro", headphoneNames: ["AirPods Pro"], muted: true, volume: 0)
        s.focus = .active
        return s
    }
}


extension SystemStatus {
    func shouldAnimate(from previous: SystemStatus) -> Bool {
        let old = previous.wifi
        return glyphs != previous.glyphs ||
            wifi.available != old.available || wifi.powered != old.powered ||
            wifi.associated != old.associated || wifi.ssid != old.ssid ||
            wifi.signalLevel != old.signalLevel ||
            (!wifi.associated && wifi.route != old.route)
    }
}
