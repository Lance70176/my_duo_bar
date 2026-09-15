import Foundation

enum FocusState: Equatable {
    case off
    case active
    case unavailable(String)
    var isActive: Bool { self == .active }
    var title: String {
        switch self {
        case .off: return "未開啟"
        case .active: return "已開啟"
        case .unavailable: return "狀態未共享"
        }
    }
    var symbol: String { isActive ? "moon.fill" : "moon" }
    static func shared(_ value: Bool?) -> FocusState {
        guard let value else { return .unavailable("系統尚未共享專注狀態") }
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
    // AC can be connected before the battery starts charging, or while charging is paused.
    var connectedToPower: Bool { present && (externalPower || charging) }
    var title: String { percent.map { "\($0)%" } ?? (present ? "讀取中" : "外接電源") }
    var detail: String {
        if !present { return "此 Mac 沒有內建電池" }
        if charging { return "正在充電" }
        if externalPower { return percent == 100 ? "電量已充滿" : "已接上電源 · 未充電" }
        if let minutesRemaining, minutesRemaining > 0 {
            return "電池供電 · 約 \(minutesRemaining / 60) 小時 \(minutesRemaining % 60) 分鐘"
        }
        return "電池供電"
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
        if associated { return ssid ?? "已連線 Wi-Fi" }
        if route == .ethernet { return "乙太網路已連線" }
        if !available { return "無 Wi-Fi 介面" }
        return powered ? "Wi-Fi 未連線" : "Wi-Fi 已關閉"
    }
    var detail: String {
        if associated {
            let quality = signalQuality
            return (ssid == nil ? "網路名稱受系統保護 · " : "") + quality
        }
        if route == .ethernet { return "正在使用有線網路" }
        return route == .offline ? "沒有可用網路路徑" : "開啟 Wi-Fi 設定以管理連線"
    }
    var signalLevel: Int {
        guard associated else { return 0 }
        return rssi.map { $0 >= -60 ? 3 : ($0 >= -72 ? 2 : 1) } ?? 3
    }
    var signalQuality: String {
        guard associated else { return powered ? "未連線" : "已關閉" }
        guard let rssi else { return "已連線" }
        if rssi >= -60 { return "訊號很好" }
        if rssi >= -72 { return "訊號一般" }
        return "訊號較弱"
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
        if !names.isEmpty { return names.joined(separator: "、") }
        if routedTunnel { return "已連線" }
        if systemProxy { return "系統代理已開啟" }
        if !available { return "狀態不可用" }
        if hasUnidentifiedTunnel { return "偵測到未識別的通道" }
        return "未連線"
    }
}

struct AudioState: Equatable {
    var outputName = "聲音輸出不可用"
    var headphoneNames: [String] = []
    var muted: Bool?
    var volume: Int?
    var headphoneActive: Bool { !headphoneNames.isEmpty }
    var headphoneTitle: String { headphoneActive ? headphoneNames.joined(separator: "、") : "未連線" }
    var soundTitle: String {
        if muted == true { return "已靜音" }
        if let volume { return "\(volume)%" }
        return muted == false ? "未靜音" : "裝置不提供音量狀態"
    }
}

enum StatusGlyph: String, CaseIterable {
    case vpn, headphones, mute, focus
    var title: String {
        switch self {
        case .vpn: return "VPN"
        case .headphones: return "耳機"
        case .mute: return "靜音"
        case .focus: return "專注"
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
        case .vpn: return "VPN 已連線"
        case .headphones: return "耳機已連線"
        case .mute: return "已靜音"
        case .focus: return "專注已開啟"
        }
    }
}

struct SystemStatus: Equatable {
    var battery = BatteryState()
    var wifi = WiFiState()
    var vpn = VPNState()
    var audio = AudioState()
    var focus: FocusState = .unavailable("需要讀取系統專注狀態")
    var glyphs: [StatusGlyph] {
        var items: [StatusGlyph] = []
        if vpn.active { items.append(.vpn) }
        if audio.headphoneActive { items.append(.headphones) }
        if audio.muted == true { items.append(.mute) }
        if focus.isActive { items.append(.focus) }
        return items
    }
    var accessibilitySummary: String {
        (["MyDuoBar", "電量 \(battery.title)", wifi.title] + glyphs.map(\.label)).joined(separator: "，")
    }
    static func preview() -> SystemStatus {
        var s = SystemStatus()
        s.battery = BatteryState(present: true, percent: 87, charging: false, externalPower: false, minutesRemaining: nil)
        s.wifi = WiFiState(available: true, powered: true, associated: true, ssid: "Home Wi-Fi", rssi: -48, route: .wifi)
        s.vpn.names = ["個人 VPN"]
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
