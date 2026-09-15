import Foundation

@main
@MainActor struct StatusTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        guard value() else { fputs("FAIL: \(description)\n", stderr); exit(1) }
    }
    static func main() {
        // String checks below are written in Traditional Chinese; pin it so the host language doesn't matter.
        L10n.overrideForTesting(.zhHant)
        for mask in 0..<16 {
            var s = SystemStatus()
            s.vpn.names = mask & 1 == 0 ? [] : ["VPN"]
            s.audio.headphoneNames = mask & 2 == 0 ? [] : ["AirPods"]
            s.audio.muted = mask & 4 != 0
            s.focus = mask & 8 == 0 ? .off : .active
            check(s.glyphs.count == mask.nonzeroBitCount, "all \(mask) state combinations identify the active dots")
            check(Set(s.glyphs.map(\.label)).count == s.glyphs.count, "no duplicated glyph for mask \(mask)")
        }
        var unknown = SystemStatus()
        unknown.vpn.hasUnidentifiedTunnel = true
        unknown.audio.muted = nil
        unknown.focus = .unavailable("denied")
        check(unknown.glyphs.isEmpty, "unknown states and ordinary tunnels never become active badges")
        check(!unknown.vpn.active, "utun is not VPN evidence")
        check(FocusState.shared(true) == .active, "shared focus on becomes moon")
        check(FocusState.shared(false) == .off, "shared focus off leaves its dot inactive")
        if case .unavailable = FocusState.shared(nil) { check(true, "unshared focus stays unknown") }
        else { check(false, "unshared focus must not become off") }
        check(SystemStatus.preview().glyphs == [.vpn, .headphones, .mute, .focus], "four active states in consistent order")
        var audio = AudioState()
        check(audio.volumeLevel == nil && !audio.showsMuteBar, "unknown volume lights no mark and shows no bar")
        for (volume, marks) in [(0, 0), (1, 1), (25, 1), (26, 2), (50, 2), (51, 3), (75, 3), (76, 4), (100, 4)] {
            audio.volume = volume
            check(audio.volumeLevel == marks, "\(volume)% lights \(marks) of the four volume marks")
        }
        check(!audio.showsMuteBar, "an unmuted output keeps the marks")
        audio.muted = true
        check(audio.showsMuteBar, "mute shows the bar instead")
        check(AudioState(headphoneNames: ["AirPods Pro"]).headphoneSymbol == "airpodspro"
              && AudioState(headphoneNames: ["AirPods Max"]).headphoneSymbol == "airpodsmax"
              && AudioState(headphoneNames: ["Sony WH-1000XM5"]).headphoneSymbol == "headphones",
              "the headphone symbol shown on connect follows the device name")
        // A fixed suite name: macOS can leave an empty plist per domain, so random names would pile up.
        let suite = "com.rex.myduobar.tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = IconPreferences(defaults: defaults)
        check(preferences.showVolume, "the volume marks show by default")
        var changes = 0
        preferences.onChange = { changes += 1 }
        preferences.setShowVolume(false)
        preferences.setShowVolume(false)
        check(changes == 1 && !preferences.showVolume, "hiding the marks notifies once")
        let restored = IconPreferences(defaults: defaults)
        check(!restored.showVolume, "the hidden choice survives reload")
        restored.setShowVolume(true)
        check(IconPreferences(defaults: defaults).showVolume, "showing the marks again is saved")
        check(!StatusGlyph.focus.isActive(in: unknown), "unshared focus never counts as active")
        check(StatusGlyph.allCases.allSatisfy { $0.isActive(in: SystemStatus.preview()) }, "each active state reports itself")
        let before = SystemStatus.preview()
        check(!before.shouldAnimate(from: before), "unchanged state does not animate")
        var changed = before; changed.battery.percent = 62
        check(!changed.shouldAnimate(from: before), "battery-only update does not animate")
        changed = before; changed.wifi.rssi = -51
        check(!changed.shouldAnimate(from: before), "RSSI noise within one signal level does not animate")
        changed.wifi.rssi = -66
        check(changed.shouldAnimate(from: before), "Wi-Fi signal level change animates")
        changed = before; changed.wifi.ssid = "Another Wi-Fi"
        check(changed.shouldAnimate(from: before), "Wi-Fi network change animates")
        changed = before; changed.wifi.associated = false
        check(changed.shouldAnimate(from: before), "Wi-Fi disconnect animates")
        changed = before; changed.vpn.names = []
        check(changed.shouldAnimate(from: before), "VPN dot change animates")
        changed = before; changed.audio.headphoneNames = []
        check(changed.shouldAnimate(from: before), "headphone dot change animates")
        changed = before; changed.audio.muted = false
        check(changed.shouldAnimate(from: before), "mute dot change animates")
        changed = before; changed.focus = .off
        check(changed.shouldAnimate(from: before), "focus dot change animates")
        func route(_ destination: UInt32, _ mask: UInt32, _ interface: String = "utun4", usable: Bool = true) -> IPv4TunnelRoute {
            IPv4TunnelRoute(interface: interface, destination: destination, mask: mask, usable: usable)
        }
        check(TunnelRoutes.ipv4Value([5, 255, 255, 255, 128], isMask: true) == 0x80000000, "Darwin compact /1 mask with non-address family")
        check(TunnelRoutes.ipv4Value([5, 255, 255, 255, 255], isMask: true) == 0xFF000000, "Darwin compact /8 mask")
        check(TunnelRoutes.ipv4Value([0], isMask: true) == 0, "default route zero-length mask")
        check(TunnelRoutes.ipv4Value([16, 2, 0], isMask: false) == nil, "truncated route address fails closed")
        let mihomo = [route(0x01000000, 0xFF000000), route(0x02000000, 0xFE000000),
            route(0x04000000, 0xFC000000), route(0x08000000, 0xF8000000),
            route(0x10000000, 0xF0000000), route(0x20000000, 0xE0000000),
            route(0x40000000, 0xC0000000), route(0x80000000, 0x80000000)]
        check(TunnelRoutePolicy.activeInterfaces(mihomo) == ["utun4"], "detect Mihomo catch-all routes with reserved-address exclusions")
        check(TunnelRoutePolicy.activeInterfaces([route(0, 0)]).count == 1, "detect tunnel default route")
        check(TunnelRoutePolicy.activeInterfaces([route(0, 0x80000000), route(0x80000000, 0x80000000)]).count == 1, "detect split default VPN")
        check(TunnelRoutePolicy.activeInterfaces([route(0, 0, "en0")]).isEmpty, "ordinary default route is not VPN")
        check(TunnelRoutePolicy.activeInterfaces([route(0, 0, usable: false)]).isEmpty, "scoped or down routes are not active")
        check(TunnelRoutePolicy.activeInterfaces([route(0xA9FE0000, 0xFFFF0000)]).isEmpty, "link-local utun is not VPN")
        check(TunnelRoutePolicy.activeInterfaces(Array(repeating: route(0x01020304, 0xFFFFFFFF), count: 50)).isEmpty, "overlapping host routes never imply catch-all VPN")
        var routed = SystemStatus(); routed.vpn.routedTunnel = true
        check(routed.glyphs == [.vpn], "route-confirmed VPN activates its dot")
        let wifi = WiFiState(available: true, powered: true, associated: true, ssid: nil, rssi: -55, route: .wifi)
        check(wifi.signalQuality == "訊號很好", "Wi-Fi signal uses plain language")
        check(wifi.title == "已連線 Wi-Fi", "redacted SSID is still connected")
        check(WiFiState(available: true, powered: false, route: .ethernet).title == "乙太網路已連線", "Ethernet is not shown as offline")
        check(BatteryState().percent == nil && BatteryState().title == "外接電源", "desktop Mac never fabricates 100 percent")
        check(AudioState().muted == nil, "unsupported mute state is not fabricated")
        check(BatteryState(present: true, percent: 50, minutesRemaining: 125).detail == "電池供電 · 約 2 小時 5 分鐘",
              "Traditional Chinese battery estimate")
        check(BatteryState(present: true, percent: 87, externalPower: true, chargeLimit: 80).detail == "已充電到 80% 上限"
              && BatteryState(present: true, percent: 60, charging: true, externalPower: true, chargeLimit: 80).detail == "正在充電到 80% 上限"
              && BatteryState(present: true, percent: 60, externalPower: true, chargeLimit: 80).detail == "已接上電源 · 未充電"
              && BatteryState(present: true, percent: 100, externalPower: true, chargeLimit: 80).detail == "電量已充滿"
              && BatteryState(present: true, percent: 87, externalPower: true).detail == "已接上電源 · 未充電",
              "the charge limit shows in the battery detail once the battery has reached it")
        check(ChargeLimitState(supported: true, enabled: true, limit: 80).activeLimit == 80
              && ChargeLimitState(supported: true, enabled: false, limit: 100).activeLimit == nil
              && ChargeLimitState(supported: false, enabled: true, limit: 80).activeLimit == nil,
              "the active limit needs support and an enabled limit below 100")

        L10n.overrideForTesting(.en)
        check(wifi.signalQuality == "Strong Signal", "English signal wording")
        check(wifi.title == "Connected to Wi-Fi", "English redacted SSID")
        check(BatteryState().title == "External Power", "English desktop power")
        check(BatteryState(present: true, percent: 50, minutesRemaining: 125).detail == "On Battery · About 2 hr 5 min",
              "English battery estimate")
        check(BatteryState(present: true, percent: 87, externalPower: true, chargeLimit: 80).detail == "Charged to 80% Limit", "English charge limit")
        var english = SystemStatus(); english.vpn.names = ["B", "A"]
        check(english.vpn.title == "B, A", "English list separator")
        check(StatusGlyph.focus.title == "Focus" && FocusState.off.title == "Off", "English dot and Focus titles")

        L10n.overrideForTesting(.ja)
        check(wifi.signalQuality == "電波良好", "Japanese signal wording")
        check(BatteryState().title == "外部電源", "Japanese desktop power")
        check(BatteryState(present: true, percent: 87, externalPower: true, chargeLimit: 80).detail == "上限 80% まで充電済み", "Japanese charge limit")
        check(StatusGlyph.focus.title == "集中モード" && FocusState.active.title == "オン", "Japanese dot and Focus titles")
        check(AudioState(muted: true).soundTitle == "消音中", "Japanese mute wording")

        // Every language must supply every phrase; spot-check that none fall back to another language.
        var seen: [AppLanguage: String] = [:]
        for language in [AppLanguage.zhHant, .en, .ja] {
            L10n.overrideForTesting(language)
            seen[language] = L10n.statusAccessNote
            check(!L10n.quit.isEmpty && !L10n.focusNotSharedBody.isEmpty, "\(language) has menu and alert text")
        }
        check(Set(seen.values).count == 3, "each language has its own settings text")

        typealias Raw = WiFiNetworkList.Raw
        let scan = [Raw(ssid: "Home", rssi: -70, secure: true, channel: 36), Raw(ssid: "Home", rssi: -50, secure: true, channel: 149),
                    Raw(ssid: "Cafe", rssi: -65, secure: false, channel: 6), Raw(ssid: "Office", rssi: -40, secure: true, channel: 1),
                    Raw(ssid: nil, rssi: -30, secure: true, channel: 11), Raw(ssid: "", rssi: -30, secure: true, channel: 11),
                    Raw(ssid: "Printer", rssi: -80, secure: true, channel: 6)]
        let grouped = WiFiNetworkList.build(raw: scan, knownSSIDs: ["Home", "Office", "Gone"], powered: true,
                                            currentSSID: "Home", currentChannel: 149, currentRSSI: -50)
        check(grouped.known.map(\.ssid) == ["Home", "Office"], "connected network first, then known networks by strength")
        check(grouped.known[0].current && grouped.known[0].rssi == -50, "duplicate access points keep the strongest signal")
        check(grouped.other.map(\.ssid) == ["Cafe", "Printer"], "unsaved networks sorted by strength, hidden names dropped")
        check(!grouped.other[0].secure && grouped.other[1].secure, "open and secured networks are told apart")
        check(!grouped.namesHidden, "named results are not reported as hidden")
        check(grouped.known.allSatisfy { $0.ssid != "Gone" }, "saved networks out of range are not listed")
        let byChannel = WiFiNetworkList.build(raw: scan, knownSSIDs: ["Home", "Office"], powered: true,
                                              currentSSID: nil, currentChannel: 149, currentRSSI: -52)
        check(byChannel.known.first?.ssid == "Home" && byChannel.known.first?.current == true,
              "the connected network is recognised by channel when its name is withheld")
        let notAssociated = WiFiNetworkList.build(raw: scan, knownSSIDs: ["Home"], powered: true,
                                                  currentSSID: nil, currentChannel: nil, currentRSSI: nil)
        check(!notAssociated.known.contains { $0.current }, "no network is marked connected when not associated")
        let redacted = WiFiNetworkList.build(raw: [Raw(ssid: nil, rssi: -50, secure: true, channel: 1)], knownSSIDs: [], powered: true,
                                             currentSSID: nil, currentChannel: nil, currentRSSI: nil)
        check(redacted.namesHidden && redacted.known.isEmpty && redacted.other.isEmpty, "withheld names ask for permission")
        check(WiFiNetworkList.build(raw: scan, knownSSIDs: ["Home"], powered: false, currentSSID: "Home",
                                    currentChannel: nil, currentRSSI: nil) == WiFiScanResult(powered: false), "Wi-Fi off lists nothing")
        check(WiFiNetwork(ssid: "a", rssi: -60, secure: false, known: false, current: false).signalLevel == 3 &&
              WiFiNetwork(ssid: "a", rssi: -72, secure: false, known: false, current: false).signalLevel == 2 &&
              WiFiNetwork(ssid: "a", rssi: -73, secure: false, known: false, current: false).signalLevel == 1,
              "network signal levels match the menu bar icon thresholds")
        check(AppLanguage.allCases.map(\.rawValue) == ["system", "zh-Hant", "en", "ja"], "language menu order and stored identifiers")
        L10n.overrideForTesting(nil)
        print("PASS: \(checks) state combinations and unavailable-data checks")
    }
}
