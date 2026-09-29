import Foundation

@main
@MainActor struct StatusTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        guard value() else { fputs("FAIL: \(description)\n", stderr); exit(1) }
    }
    /// The power reading from the registry and the CSV log format.
    static func powerChecks() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let plugged: [String: Any] = [
            "ExternalConnected": true, "UpdateTime": 1_790_699_564, "Voltage": 12195, "Amperage": 2069, "CurrentCapacity": 24, "MaxCapacity": 100,
            "AdapterDetails": ["Watts": 45, "AdapterVoltage": 20000, "Current": 2250, "Description": "pd charger"],
            "PowerTelemetryData": ["SystemPowerIn": 43444, "SystemVoltageIn": 19403, "SystemCurrentIn": 2239, "SystemLoad": 16198]
        ]
        let sample = PowerReader.parse(registry: plugged, date: now)
        check(sample?.adapterWatts == 45 && sample?.adapterVolts == 20 && sample?.adapterAmps == 2.25
              && sample?.inputWatts == 43.444 && sample?.inputVolts == 19.403 && sample?.inputAmps == 2.239
              && sample?.systemWatts == 16.198 && abs((sample?.batteryWatts ?? 0) - 25.231) < 0.001 && sample?.percent == 24,
              "the registry gives the adapter rating, the live input, the system load and the battery power")
        let unplugged: [String: Any] = [
            "ExternalConnected": false, "Voltage": 12000, "Amperage": NSNumber(value: UInt64(bitPattern: -1500)),
            "AdapterDetails": ["Watts": 45], "PowerTelemetryData": ["SystemPowerIn": 0, "SystemLoad": 18000]
        ]
        let onBattery = PowerReader.parse(registry: unplugged, date: now)
        check(onBattery?.connected == false && onBattery?.inputWatts == 0 && onBattery?.batteryWatts == -18,
              "on battery there is no adapter and a wrapped negative current reads as discharge")
        check(PowerReader.parse(registry: ["BatteryInstalled": false], date: now) == nil, "no installed battery means no power reading")
        if let sample {
            var same = sample; same.date = now.addingTimeInterval(10)
            var refreshed = same; refreshed.updateTime = 1_790_699_594
            var unpluggedNow = same; unpluggedNow.adapterWatts = nil
            check(!same.isNew(after: sample) && refreshed.isNew(after: sample) && unpluggedNow.isNew(after: sample)
                  && sample.isNew(after: nil) && PowerSample(date: now).isNew(after: sample),
                  "only a registry refresh or a plug change counts as a new reading")
        }

        guard let sample else { return }
        let line = PowerLogFile.line(sample)
        check(line.hasSuffix(",45,43.44,19.40,2.24,25.23,16.20,24") && line.split(separator: ",").count == 8,
              "a log line holds the time, rating, input, battery and system power and the level")
        let parsed = PowerLogFile.parse(line: line)
        check(parsed?.date == now && parsed?.adapterWatts == 45 && parsed?.inputWatts == 43.44 && parsed?.percent == 24,
              "a log line reads back")
        check(PowerLogFile.parse(line: PowerLogFile.header) == nil, "the header is not a sample")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myduobar-power-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = PowerSample(date: now.addingTimeInterval(-3 * 3600), adapterWatts: 45, inputWatts: 30)
        PowerLogFile.append([old, sample], to: url)
        PowerLogFile.append([PowerSample(date: now.addingTimeInterval(10), inputWatts: 0)], to: url)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let loaded = PowerLogFile.load(from: url, since: now.addingTimeInterval(-3600))
        check(text.hasPrefix(PowerLogFile.header + "\n") && text.split(separator: "\n").count == 4
              && loaded.map(\.date) == [now, now.addingTimeInterval(10)] && loaded.last?.connected == false,
              "the log gets one header, appends samples and loads only the recent ones in order")
    }

    static func main() {
        // String checks below are written in Traditional Chinese; pin it so the host language doesn't matter.
        L10n.overrideForTesting(.zhHant)
        for mask in 0..<8 {
            var s = SystemStatus()
            s.vpn.names = mask & 1 == 0 ? [] : ["VPN"]
            s.audio.headphoneNames = mask & 2 == 0 ? [] : ["AirPods"]
            s.audio.muted = mask & 4 != 0
            check(s.glyphs.count == mask.nonzeroBitCount, "all \(mask) state combinations identify the active dots")
            check(Set(s.glyphs.map(\.label)).count == s.glyphs.count, "no duplicated glyph for mask \(mask)")
        }
        var unknown = SystemStatus()
        unknown.vpn.hasUnidentifiedTunnel = true
        unknown.audio.muted = nil
        check(unknown.glyphs.isEmpty, "unknown states and ordinary tunnels never become active badges")
        check(!unknown.vpn.active, "utun is not VPN evidence")
        check(SystemStatus.preview().glyphs == [.vpn, .headphones, .mute], "three active states in consistent order")
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
        check(ChargeLimitState(supported: true, enabled: true, limit: 24, levels: [80, 85, 90, 95]).setElsewhere
              && !ChargeLimitState(supported: true, enabled: true, limit: 80, levels: [80, 85, 90, 95]).setElsewhere
              && !ChargeLimitState(supported: true, enabled: false, limit: 100, levels: [80, 85, 90, 95]).setElsewhere
              && !ChargeLimitState(supported: true, enabled: true, limit: 24).setElsewhere,
              "a limit macOS does not offer means another app set it")
        check(BatteryState(present: true, percent: 24, externalPower: true, chargeLimit: 24, chargeLimitSetElsewhere: true).detail == "其他 App 已暫停充電"
              && BatteryState(present: true, percent: 29, externalPower: true, chargeLimit: 79, chargeLimitSetElsewhere: true).detail == "已接上電源 · 未充電"
              && BatteryState(present: true, percent: 29, charging: true, externalPower: true, chargeLimit: 79, chargeLimitSetElsewhere: true).detail == "正在充電到 79% 上限",
              "only another app's limit at the current level reads as paused")
        let registry: [String: Any] = ["BatteryInstalled": true, "CycleCount": 239, "DesignCycleCount9C": 1000,
                                       "BatteryData": ["DesignCapacity": 6075, "NominalChargeCapacity": 5191]]
        let estimated = BatteryHealthService.parse(registry: registry)
        check(estimated == BatteryHealth(maximumCapacity: 85, condition: .unknown, cycleCount: 239, designCycleCount: 1000),
              "the registry gives the cycle counts and a capacity estimate from the pack's own figures")
        check(BatteryHealthService.parse(registry: ["BatteryInstalled": false]) == nil, "no installed battery means no health")
        powerChecks()
        let profile = Data("""
        {"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":{"sppower_battery_cycle_count":239,\
        "sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"84%"}},{"_name":"sppower_ac_charger_information"}]}
        """.utf8)
        let profiled = BatteryHealthService.parse(profile: profile)
        check(profiled == BatteryHealth(maximumCapacity: 84, condition: .normal, cycleCount: 239, designCycleCount: nil),
              "the profiler gives macOS's own maximum capacity and condition")
        check(BatteryHealthService.parse(profile: Data("{}".utf8)) == nil, "a profile without a battery gives nil")
        var health = estimated!
        health.merge(profiled!)
        check(health.maximumCapacity == 84 && health.condition == .normal && health.cycleCount == 239 && health.designCycleCount == 1000,
              "the profiler's figures win and the registry keeps the design cycle count")
        check(health.capacityLine == "最大容量 84% · 正常" && health.cycleLine == "循環次數 239（設計 1000）", "Chinese health lines")
        var worn = health; worn.condition = .serviceRecommended; worn.designCycleCount = nil
        check(worn.capacityLine == "最大容量 84% · 建議維修" && worn.cycleLine == "循環次數 239", "service recommended and no design count")
        check(BatteryHealth().capacityLine == "讀取中" && BatteryHealth().cycleLine == "讀取中", "unknown health reads as reading")

        L10n.overrideForTesting(.en)
        check(health.capacityLine == "Maximum Capacity 84% · Normal" && health.cycleLine == "Cycle Count 239 of 1000", "English health lines")
        check(wifi.signalQuality == "Strong Signal", "English signal wording")
        check(wifi.title == "Connected to Wi-Fi", "English redacted SSID")
        check(BatteryState().title == "External Power", "English desktop power")
        check(BatteryState(present: true, percent: 50, minutesRemaining: 125).detail == "On Battery · About 2 hr 5 min",
              "English battery estimate")
        check(BatteryState(present: true, percent: 87, externalPower: true, chargeLimit: 80).detail == "Charged to 80% Limit", "English charge limit")
        var english = SystemStatus(); english.vpn.names = ["B", "A"]
        check(english.vpn.title == "B, A", "English list separator")
        check(StatusGlyph.mute.title == "Mute" && L10n.off == "Off", "English dot and off titles")

        L10n.overrideForTesting(.ja)
        check(wifi.signalQuality == "電波良好", "Japanese signal wording")
        check(BatteryState().title == "外部電源", "Japanese desktop power")
        check(BatteryState(present: true, percent: 87, externalPower: true, chargeLimit: 80).detail == "上限 80% まで充電済み", "Japanese charge limit")
        check(health.capacityLine == "最大容量 84% · 正常" && health.cycleLine == "充放電回数 239（設計 1000）", "Japanese health lines")
        check(StatusGlyph.mute.title == "消音" && L10n.off == "オフ", "Japanese dot and off titles")
        check(AudioState(muted: true).soundTitle == "消音中", "Japanese mute wording")

        // Every language must supply every phrase; spot-check that none fall back to another language.
        var seen: [AppLanguage: String] = [:]
        for language in [AppLanguage.zhHant, .en, .ja] {
            L10n.overrideForTesting(language)
            seen[language] = L10n.statusAccessNote
            check(!L10n.quit.isEmpty && !L10n.loginItemFailed.isEmpty, "\(language) has menu and alert text")
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
