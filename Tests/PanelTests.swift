import AppKit
import CoreAudio

@main @MainActor struct PanelTests {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    static func main() {
        _ = NSApplication.shared
        var opened: [SystemSettings.Page] = []
        do {
            let expected: [SystemSettings.Page] = [.focus]
            let panel = StatusPanel()
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: panel.frame.width, height: panel.frame.height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = panel; window.orderFront(nil)
            defer { window.orderOut(nil) }
            panel.layoutSubtreeIfNeeded()
            let rows = descendants(panel).compactMap { $0 as? StatusRow }
            check(rows.map(\.destination) == expected, "each panel block holds its own rows")
            opened.removeAll()
            panel.onOpenSettings = { opened.append($0) }
            for row in rows {
                check(row.accessibilityRole() == .button, "status rows expose a button action")
                check(row.hitTest(NSPoint(x: row.frame.midX, y: row.frame.midY)) === row,
                      "the whole row, including its labels, is clickable")
                row.performClick(nil)
            }
            check(opened == expected, "rows open their settings pages")
            // Compact rows keep a hidden detail label below them; only drawn views have to fit.
            let lowest = descendants(panel).filter { !$0.isHiddenOrHasHiddenAncestor }
                .map { $0.convert($0.bounds, to: panel).minY }.min() ?? 0
            check(lowest >= 0, "rows fit inside their panel block")
        }

        L10n.overrideForTesting(.zhHant)
        let wifiMenu = WiFiMenuController()
        wifiMenu.onOpenSettings = { opened.append($0) }
        var wired = SystemStatus(); wired.wifi.route = .ethernet
        wifiMenu.update(status: wired)
        check(wifiMenu.item.submenu == nil && wifiMenu.item.action != nil, "a Mac without Wi-Fi hardware gets a plain item")
        NSApp.sendAction(wifiMenu.item.action!, to: wifiMenu.item.target, from: wifiMenu.item)
        check(opened.last == .network, "without Wi-Fi hardware the item opens network settings")

        var wireless = SystemStatus()
        wireless.wifi = WiFiState(available: true, powered: true, associated: true, ssid: "Home", rssi: -50, route: .wifi)
        wifiMenu.update(status: wireless)
        check(wifiMenu.item.submenu === wifiMenu.submenu && wifiMenu.item.action == nil, "Wi-Fi opens a submenu to the right")
        check(wifiMenu.item.title == "Wi-Fi" && wifiMenu.item.subtitle == "Home · 訊號很好", "the item shows network and signal")

        wifiMenu.rebuild()
        check(wifiMenu.submenu.items.first?.view is WiFiToggleRowView, "the submenu starts with the Wi-Fi switch")
        check(wifiMenu.submenu.items.contains { $0.title == "正在搜尋網路…" && !$0.isEnabled }, "before the first scan it says it is scanning")

        typealias Raw = WiFiNetworkList.Raw
        wifiMenu.finishScan(WiFiNetworkList.build(
            raw: [Raw(ssid: "Home", rssi: -50, secure: true, channel: 149), Raw(ssid: "Office", rssi: -60, secure: true, channel: 1),
                  Raw(ssid: "Cafe", rssi: -65, secure: false, channel: 6)],
            knownSSIDs: ["Home", "Office"], powered: true, currentSSID: "Home", currentChannel: 149, currentRSSI: -50))
        wifiMenu.rebuild()
        let items = wifiMenu.submenu.items
        check(items.contains { $0.isSectionHeader && $0.title == "已知的網路" }, "known networks have a section header")
        let knownRows = items.compactMap { $0.view as? WiFiNetworkRowView }
        check(knownRows.map(\.network.ssid) == ["Home", "Office"] && knownRows[0].network.current, "known networks listed with the connected one first")
        guard let other = items.first(where: { $0.title == "其他網路" })?.submenu else { check(false, "other networks item has a submenu"); return }
        check(other.items.compactMap { ($0.view as? WiFiNetworkRowView)?.network.ssid } == ["Cafe"], "other networks open in a nested submenu")
        check(items.last?.title == "Wi-Fi 設定…", "the submenu ends with Wi-Fi Settings")
        NSApp.sendAction(items.last!.action!, to: items.last!.target, from: items.last!)
        check(opened.last == .wifi, "Wi-Fi Settings opens the Wi-Fi page")

        wifiMenu.finishScan(WiFiNetworkList.build(raw: [Raw(ssid: nil, rssi: -50, secure: true, channel: 1)], knownSSIDs: [],
                                                  powered: true, currentSSID: nil, currentChannel: nil, currentRSSI: nil))
        wifiMenu.rebuild()
        check(wifiMenu.submenu.items.contains { $0.title == "允許顯示網路名稱…" }, "withheld names offer the permission request")

        var off = wireless; off.wifi.powered = false; off.wifi.associated = false
        wifiMenu.update(status: off)
        wifiMenu.rebuild()
        check(wifiMenu.submenu.items.compactMap { $0.view as? WiFiNetworkRowView }.isEmpty &&
              (wifiMenu.submenu.items.first?.view as? WiFiToggleRowView)?.toggle.isOn == false,
              "Wi-Fi off shows only the switch and settings")
        check(wifiMenu.item.subtitle == "已關閉", "the item says Wi-Fi is off")
        vpnChecks()
        soundChecks()
        outputChecks()
        batteryChecks()
        L10n.overrideForTesting(nil)
        check(SystemSettings.Page.bluetooth.url.absoluteString == "x-apple.systempreferences:com.apple.BluetoothSettings", "headphones target Bluetooth settings")
        check(SystemSettings.Page.allCases.allSatisfy { $0.url.scheme == "x-apple.systempreferences" },
              "settings links stay within the system settings application")
        print("PASS: native settings actions, Wi-Fi, Battery, VPN, Headphones and Sound submenus, custom controls and network routing")
    }

    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Exercises the VPN submenu against a fake service: nothing real is connected or disconnected.
    static func vpnChecks() {
        let fake = FakeVPNService([VPNConfiguration(id: "b", name: "Tailscale", status: .connected),
                                   VPNConfiguration(id: "a", name: "Surfshark", status: .disconnected)])
        let vpn = VPNMenuController()
        vpn.service = fake
        var opened: [SystemSettings.Page] = []
        var changes = 0
        vpn.onOpenSettings = { opened.append($0) }
        vpn.onVPNChanged = { changes += 1 }
        var state = SystemStatus(); state.vpn.names = ["Tailscale"]
        vpn.update(status: state)
        check(vpn.item.submenu === vpn.submenu && vpn.item.subtitle == "Tailscale", "VPN opens a submenu and shows the active VPN")

        vpn.menuWillOpen(vpn.submenu)
        spin(0.2)
        let rows = { vpn.submenu.items.compactMap { $0.view as? VPNRowView } }
        check(rows().map(\.configuration.name) == ["Tailscale", "Surfshark"], "every registered VPN gets a row")
        check(rows()[0].toggleSwitch.isOn && !rows()[1].toggleSwitch.isOn, "switches mirror connection status")
        check(vpn.submenu.items.first?.isSectionHeader == true && vpn.submenu.items.last?.title == "VPN 設定…",
              "the submenu has a VPN header and ends with VPN Settings")

        let surfshark = rows()[1]
        surfshark.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: surfshark.convert(NSPoint(x: 100, y: 20), to: nil),
                                                   modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 0) ?? NSEvent())
        check(fake.calls == ["start a"] || rows()[1].configuration.status == .connecting, "clicking a row starts connecting at once")
        spin(0.4)
        check(fake.calls == ["start a"], "clicking a disconnected VPN asks macOS to connect it")
        check(rows()[1].configuration.status == .connected && rows()[1].toggleSwitch.isOn, "the row follows the status until connected")
        check(changes == 1 && opened.isEmpty, "a settled connection refreshes status without leaving the menu")

        vpn.toggle(id: "b")
        spin(0.4)
        check(fake.calls.last == "stop b" && rows()[0].configuration.status == .disconnected, "turning a VPN off disconnects it")

        fake.refuseStart = true
        vpn.toggle(id: "b")
        spin(0.4)
        check(opened == [.vpn] && rows()[0].configuration.status == .disconnected, "a refused start hands over to VPN settings")

        fake.refuseStart = false
        fake.neverConnects = true
        vpn.menuWillOpen(vpn.submenu)
        spin(0.2)
        vpn.toggle(id: "b")
        spin(0.6)
        check(rows()[0].configuration.status == .disconnected && !rows()[0].toggleSwitch.isOn,
              "a VPN that fails to connect falls back to off instead of spinning forever")

        state.vpn.names = []; state.vpn.routedTunnel = true
        vpn.update(status: state)
        vpn.rebuild()
        check(!vpn.submenu.items.contains { $0.title == "偵測到其他 VPN 路由，無法在此切換" },
              "a tunnel route is not reported separately while a managed VPN is on")
        vpn.toggle(id: "a")
        spin(0.4)
        vpn.rebuild()
        check(vpn.submenu.items.contains { $0.title == "偵測到其他 VPN 路由，無法在此切換" && !$0.isEnabled },
              "VPNs macOS doesn't manage are reported, not offered as switches")

        let empty = VPNMenuController()
        empty.service = FakeVPNService([])
        empty.menuWillOpen(empty.submenu)
        spin(0.2)
        check(empty.submenu.items.contains { $0.title == "系統中沒有 VPN 設定" }, "no registered VPN says so")
        empty.menuDidClose(empty.submenu)
        vpn.menuDidClose(vpn.submenu)

        let toggled = MenuSwitch(isOn: false)
        var fired = 0
        let target = ActionTarget { fired += 1 }
        toggled.target = target; toggled.action = #selector(ActionTarget.fire)
        toggled.toggle()
        check(toggled.isOn && fired == 1, "the menu switch flips and fires its action")
        toggled.isEnabled = false
        toggled.toggle()
        check(toggled.isOn && fired == 1, "a disabled menu switch ignores clicks")
    }
}

extension PanelTests {
    /// Exercises the Sound submenu against a fake output: the Mac's real volume is never changed.
    static func soundChecks() {
        let fake = FakeSoundService(SoundOutput(name: "MacBook Pro 喇叭", volume: 0.5, muted: false, canSetVolume: true, canSetMute: true))
        let sound = SoundMenuController()
        sound.service = fake
        var opened: [SystemSettings.Page] = []
        sound.onOpenSettings = { opened.append($0) }
        var state = SystemStatus()
        state.audio = AudioState(outputName: "MacBook Pro 喇叭", headphoneNames: [], muted: false, volume: 50)
        sound.update(status: state)
        check(sound.item.submenu === sound.submenu && sound.item.title == "聲音" && sound.item.subtitle == "MacBook Pro 喇叭 · 50%",
              "Sound opens a submenu and shows the output and level")
        check(SoundMenuController.symbol(muted: false, percent: 80) == "speaker.wave.3.fill"
              && SoundMenuController.symbol(muted: true, percent: 80) == "speaker.slash.fill"
              && SoundMenuController.symbol(muted: false, percent: 0) == "speaker.fill", "the speaker symbol follows level and mute")

        sound.menuWillOpen(sound.submenu)
        spin(0.2)
        check(sound.submenu.items.first?.isSectionHeader == true && sound.submenu.items[1].view === sound.volumeRow
              && sound.submenu.items[2].view === sound.muteRow && sound.submenu.items.last?.title == "聲音設定…",
              "the submenu has a header, the slider, the mute row below it and Sound Settings")
        check(sound.volumeRow.slider.value == 0.5 && sound.volumeRow.levelText == "50%" && sound.volumeRow.deviceText == "MacBook Pro 喇叭",
              "the slider shows the output's volume")
        check(!sound.muteRow.toggleSwitch.isOn && sound.muteRow.symbolName == "speaker.wave.2.fill" && sound.muteRow.detailText == "未靜音",
              "the mute row shows a speaker and its switch is off")

        sound.volumeRow.slider.setValueFromUser(0.8)
        spin(0.2)
        check(fake.output.volume == 0.8 && sound.volumeRow.levelText == "80%", "moving the slider sets the volume")
        for step in 1...20 { sound.volumeRow.slider.setValueFromUser(Float(step) / 20) }
        spin(0.3)
        check(fake.output.volume == 1 && fake.volumeWrites < 21, "a fast drag ends on the last value without queuing every step")
        fake.setExternally(volume: 0.3)
        sound.reload()
        spin(0.1)
        check(sound.volumeRow.slider.value == 1, "a read taken right after a drag doesn't pull the slider back")

        let mute = sound.muteRow
        mute.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: mute.convert(NSPoint(x: 100, y: 20), to: nil),
                                              modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 0) ?? NSEvent())
        spin(0.1)
        check(fake.output.muted == true && mute.toggleSwitch.isOn && mute.symbolName == "speaker.slash.fill"
              && mute.detailText == "已靜音" && sound.volumeRow.levelText == "已靜音" && sound.volumeRow.slider.dimmed,
              "clicking the mute row mutes and swaps the speaker icon")
        sound.volumeRow.slider.setValueFromUser(0.6)
        spin(0.1)
        check(fake.output.muted == false && !mute.toggleSwitch.isOn, "raising the volume while muted unmutes")

        spin(SoundMenuController.settleTime + 0.2)
        fake.setExternally(volume: 0.2)
        sound.update(status: state)
        spin(0.2)
        check(sound.volumeRow.slider.value == 0.2, "after settling, changes made elsewhere show up while the submenu is open")

        fake.setExternally(volume: 0)
        sound.reload()
        spin(0.2)
        check(mute.toggleSwitch.isOn, "zero volume counts as muted")
        sound.toggleMute()
        spin(0.1)
        check(fake.output.muted == false && fake.output.volume == SoundMenuController.unmuteVolume,
              "unmuting a silent output brings the volume back up")

        spin(SoundMenuController.settleTime + 0.2)
        fake.replace(SoundOutput(name: "HDMI", volume: 0.4, muted: nil, canSetVolume: true, canSetMute: false))
        sound.reload()
        spin(0.2)
        sound.toggleMute()
        spin(0.1)
        check(fake.output.volume == 0 && mute.toggleSwitch.isOn, "an output without a mute switch is muted by zeroing its volume")
        sound.toggleMute()
        spin(0.1)
        check(fake.output.volume == 0.4 && !mute.toggleSwitch.isOn, "and unmuting restores the earlier level")

        spin(SoundMenuController.settleTime + 0.2)
        fake.replace(SoundOutput(name: "Display", volume: nil, muted: nil, canSetVolume: false, canSetMute: false))
        sound.reload()
        spin(0.2)
        let writes = fake.volumeWrites
        sound.volumeRow.slider.setValueFromUser(0.9)
        sound.toggleMute()
        spin(0.1)
        check(!sound.volumeRow.slider.isEnabled && !mute.toggleSwitch.isEnabled && fake.volumeWrites == writes
              && mute.detailText == "此裝置無法靜音" && sound.volumeRow.levelText == "—",
              "an output with no volume control disables both controls")

        L10n.overrideForTesting(.ja)
        sound.rebuild()
        check(sound.submenu.items.first?.title == "サウンド" && sound.submenu.items.last?.title == "サウンド設定…",
              "the submenu follows the app language")
        L10n.overrideForTesting(.zhHant)

        sound.submenu.items.last.map { item in _ = (item.target as? NSObject)?.perform(item.action) }
        check(opened == [.sound], "Sound Settings opens the Sound page")
        sound.menuDidClose(sound.submenu)

        let slider = MenuSlider()
        slider.frame = NSRect(x: 0, y: 0, width: 116, height: MenuSlider.height)
        check(slider.value(atX: 0) == 0 && slider.value(atX: 58) == 0.5 && slider.value(atX: 500) == 1, "slider positions map to 0…1")
        slider.value = 3
        check(slider.value == 1, "slider values are clamped")
        check(slider.accessibilityPerformDecrement() && slider.value == 1 - MenuSlider.step, "VoiceOver can step the slider")
    }
}

extension PanelTests {
    /// Exercises the Headphones submenu against fake devices: the real default output is never changed.
    static func outputChecks() {
        let speakers = AudioOutputDevice(id: 1, name: "MacBook Pro 喇叭", symbol: "speaker.wave.2.fill", isHeadphone: false, isDefault: true)
        let airpods = AudioOutputDevice(id: 2, name: "AirPods Pro", symbol: "airpodspro", isHeadphone: true, isDefault: false)
        let fake = FakeOutputDeviceService([speakers, airpods])
        let output = OutputMenuController()
        output.service = fake
        var opened: [SystemSettings.Page] = []
        var changes = 0
        output.onOpenSettings = { opened.append($0) }
        output.onOutputChanged = { changes += 1 }
        var state = SystemStatus()
        state.audio.headphoneNames = ["AirPods Pro"]
        output.update(status: state)
        check(output.item.submenu === output.submenu && output.item.title == "耳機" && output.item.subtitle == "AirPods Pro",
              "Headphones opens a submenu and shows the connected headphones")

        output.menuWillOpen(output.submenu)
        spin(0.2)
        let rows = { output.submenu.items.filter { $0.representedObject is NSNumber } }
        check(output.submenu.items.first?.isSectionHeader == true && output.submenu.items.first?.title == "輸出裝置"
              && output.submenu.items.last?.title == "藍牙設定…", "the submenu has an Output header and ends with Bluetooth Settings")
        check(rows().map(\.title) == ["MacBook Pro 喇叭", "AirPods Pro"] && rows().map(\.state) == [.on, .off] && rows().allSatisfy { $0.image != nil },
              "every output device is listed with an icon and the current one checked")

        rows()[1].target.map { _ = ($0 as? NSObject)?.perform(rows()[1].action, with: rows()[1]) }
        spin(0.2)
        check(fake.selections == [2] && rows().map(\.state) == [.off, .on] && changes == 1, "choosing a device makes it the default output")
        output.select(id: 2)
        spin(0.1)
        check(fake.selections == [2], "choosing the current device does nothing")

        fake.refuse = true
        output.select(id: 1)
        spin(0.2)
        check(opened == [.sound] && rows().map(\.state) == [.off, .on], "a refused switch opens Sound settings and keeps the check")

        fake.replace([speakers])
        output.update(status: state)
        spin(0.2)
        check(rows().map(\.title) == ["MacBook Pro 喇叭"], "a device that disconnects leaves the open submenu")
        output.menuDidClose(output.submenu)

        check(AudioOutputDevice.symbol(name: "AirPods Max", transport: nil, headphone: true) == "airpodsmax"
              && AudioOutputDevice.symbol(name: "LG HDR 4K", transport: kAudioDeviceTransportTypeHDMI, headphone: false) == "tv"
              && AudioOutputDevice.symbol(name: "Sony WH-1000XM5", transport: kAudioDeviceTransportTypeBluetooth, headphone: true) == "headphones",
              "device icons follow the device kind")
    }
}

extension PanelTests {
    /// Exercises the Battery submenu against a fake limit: the Mac's real charge limit is never changed.
    static func batteryChecks() {
        let suite = "com.rex.myduobar.tests.battery"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeChargeLimitService(ChargeLimitState(supported: true, enabled: true, limit: 80, levels: [80, 85, 90, 95]))
        let menu = BatteryMenuController(defaults: defaults)
        menu.service = fake
        var opened: [SystemSettings.Page] = []
        var changes = 0
        menu.onOpenSettings = { opened.append($0) }
        menu.onChargeLimitChanged = { changes += 1 }
        var state = SystemStatus()
        state.battery = BatteryState(present: true, percent: 87, charging: false, externalPower: true, chargeLimit: 80)
        menu.update(status: state)
        check(menu.item.submenu === menu.submenu && menu.item.title == "電池" && menu.item.subtitle == "87% · 已充電到 80% 上限",
              "Battery opens a submenu and shows the level and the limit")
        check(BatteryMenuController.symbol(state.battery) == "battery.75percent"
              && BatteryMenuController.symbol(BatteryState(present: true, percent: 10, charging: true)) == "battery.100percent.bolt"
              && BatteryMenuController.symbol(BatteryState(present: true, percent: 10)) == "battery.0percent"
              && BatteryMenuController.symbol(BatteryState()) == "powerplug", "the battery symbol follows level and charging")

        menu.menuWillOpen(menu.submenu)
        spin(0.2)
        check(menu.submenu.items.first?.isSectionHeader == true && menu.submenu.items.first?.title == "充電上限"
              && menu.submenu.items[1].view === menu.limitRow && menu.submenu.items.last?.title == "電池設定…",
              "the submenu has a Charge Limit header, the switch row and Battery Settings")
        check(menu.levelItems.map(\.title) == ["停在 80%", "停在 85%", "停在 90%", "停在 95%"] && menu.levelItems.map(\.state) == [.on, .off, .off, .off],
              "every level macOS offers is listed with the active one checked")
        check(menu.limitRow.toggleSwitch.isOn && menu.limitRow.detailText == "充到 80% 就停止充電", "the switch is on and names the limit")

        let row = menu.limitRow
        row.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: row.convert(NSPoint(x: 100, y: 20), to: nil),
                                             modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 0) ?? NSEvent())
        check(!row.toggleSwitch.isOn, "clicking the row turns the switch off at once")
        spin(0.2)
        check(fake.calls == ["disable"] && !row.toggleSwitch.isOn && row.detailText == "未限制，會充到 100%"
              && menu.levelItems.allSatisfy { $0.state == .off } && changes == 1 && opened.isEmpty,
              "turning the limit off asks macOS to disable it and unchecks every level")

        menu.toggleLimit()
        spin(0.2)
        check(fake.calls.last == "set 80" && row.toggleSwitch.isOn && menu.levelItems[0].state == .on,
              "turning it back on restores the last level")

        let ninety = menu.levelItems[2]
        ninety.target.map { _ = ($0 as? NSObject)?.perform(ninety.action, with: ninety) }
        spin(0.2)
        check(fake.calls.last == "set 90" && menu.levelItems.map(\.state) == [.off, .off, .on, .off] && row.detailText == "充到 90% 就停止充電"
              && defaults.integer(forKey: BatteryMenuController.levelKey) == 90, "choosing a level sets it and remembers it")
        menu.setLimit(nil)
        spin(0.2)
        menu.toggleLimit()
        spin(0.2)
        check(fake.calls.last == "set 90" && changes == 5, "the switch comes back on at the remembered level")

        fake.refuse = true
        menu.setLimit(85)
        spin(0.2)
        check(opened == [.battery] && changes == 5 && menu.levelItems.map(\.state) == [.off, .off, .on, .off],
              "a refused change opens Battery settings and keeps the real value")
        fake.refuse = false

        fake.setExternally(ChargeLimitState(supported: true, enabled: true, limit: 95, levels: [80, 85, 90, 95]))
        menu.update(status: state)
        spin(0.2)
        check(menu.levelItems.map(\.state) == [.off, .off, .off, .on] && defaults.integer(forKey: BatteryMenuController.levelKey) == 95,
              "a limit chosen in System Settings shows up while the submenu is open and becomes the remembered level")

        L10n.overrideForTesting(.en)
        menu.rebuild()
        check(menu.submenu.items.first?.title == "Charge Limit" && menu.levelItems.first?.title == "Stop at 80%"
              && menu.submenu.items.last?.title == "Battery Settings…", "the submenu follows the app language")
        L10n.overrideForTesting(.zhHant)
        menu.submenu.items.last.map { item in _ = (item.target as? NSObject)?.perform(item.action) }
        check(opened == [.battery, .battery], "Battery Settings opens the Battery page")
        menu.menuDidClose(menu.submenu)

        let unsupported = BatteryMenuController(defaults: defaults)
        unsupported.service = FakeChargeLimitService(.unsupported)
        unsupported.menuWillOpen(unsupported.submenu)
        spin(0.2)
        check(!unsupported.limitRow.toggleSwitch.isEnabled && unsupported.limitRow.detailText == "此 Mac 或此版 macOS 不提供充電上限"
              && unsupported.levelItems.isEmpty, "without the system charge limit the switch is disabled and says why")
        unsupported.toggleLimit()
        spin(0.1)
        unsupported.menuDidClose(unsupported.submenu)
    }
}

final class ActionTarget: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}

/// In-memory VPN service for tests. Starts connect after one poll; stops disconnect immediately.
final class FakeVPNService: VPNServing, @unchecked Sendable {
    private let lock = NSLock()
    private var configs: [VPNConfiguration]
    private var _calls: [String] = []
    private var _refuseStart = false
    private var _neverConnects = false
    init(_ configs: [VPNConfiguration]) { self.configs = configs }

    var calls: [String] { lock.withLock { _calls } }
    var refuseStart: Bool { get { lock.withLock { _refuseStart } } set { lock.withLock { _refuseStart = newValue } } }
    var neverConnects: Bool { get { lock.withLock { _neverConnects } } set { lock.withLock { _neverConnects = newValue } } }
    var pollInterval: TimeInterval { 0.01 }

    func list() -> [VPNConfiguration] { lock.withLock { configs } }
    func status(id: String) -> VPNConnectionStatus { lock.withLock { configs.first { $0.id == id }?.status ?? .invalid } }
    func start(id: String) -> Bool {
        lock.withLock {
            _calls.append("start \(id)")
            guard !_refuseStart else { return false }
            if let index = configs.firstIndex(where: { $0.id == id }) { configs[index].status = _neverConnects ? .disconnected : .connected }
            return true
        }
    }
    func stop(id: String) -> Bool {
        lock.withLock {
            _calls.append("stop \(id)")
            if let index = configs.firstIndex(where: { $0.id == id }) { configs[index].status = .disconnected }
            return true
        }
    }
}

/// In-memory output device for tests.
final class FakeSoundService: SoundServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _output: SoundOutput
    private var _volumeWrites = 0
    init(_ output: SoundOutput) { _output = output }

    var output: SoundOutput { lock.withLock { _output } }
    var volumeWrites: Int { lock.withLock { _volumeWrites } }
    func setExternally(volume: Float) { lock.withLock { _output.volume = volume } }
    func replace(_ output: SoundOutput) { lock.withLock { _output = output } }

    func read() -> SoundOutput { output }
    func setVolume(_ volume: Float) -> Bool {
        // A little latency, like a real device, so drags coalesce.
        Thread.sleep(forTimeInterval: 0.01)
        return lock.withLock {
            _volumeWrites += 1
            guard _output.canSetVolume else { return false }
            _output.volume = volume
            return true
        }
    }
    func setMuted(_ muted: Bool) -> Bool {
        lock.withLock {
            guard _output.canSetMute else { return false }
            _output.muted = muted
            return true
        }
    }
}

/// In-memory charge limit for tests.
final class FakeChargeLimitService: ChargeLimitServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: ChargeLimitState
    private var _calls: [String] = []
    private var _refuse = false
    init(_ state: ChargeLimitState) { _state = state }

    var calls: [String] { lock.withLock { _calls } }
    var refuse: Bool { get { lock.withLock { _refuse } } set { lock.withLock { _refuse = newValue } } }
    func setExternally(_ state: ChargeLimitState) { lock.withLock { _state = state } }

    func read() -> ChargeLimitState { lock.withLock { _state } }
    func setLimit(_ percent: Int) -> Bool {
        lock.withLock {
            _calls.append("set \(percent)")
            guard !_refuse else { return false }
            _state.enabled = percent < 100
            _state.limit = percent
            return true
        }
    }
    func disable() -> Bool {
        lock.withLock {
            _calls.append("disable")
            guard !_refuse else { return false }
            _state.enabled = false
            _state.limit = 100
            return true
        }
    }
}

/// In-memory output devices for tests.
final class FakeOutputDeviceService: OutputDeviceServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [AudioOutputDevice]
    private var _selections: [UInt32] = []
    private var _refuse = false
    init(_ devices: [AudioOutputDevice]) { _devices = devices }

    var selections: [UInt32] { lock.withLock { _selections } }
    var refuse: Bool { get { lock.withLock { _refuse } } set { lock.withLock { _refuse = newValue } } }
    func replace(_ devices: [AudioOutputDevice]) { lock.withLock { _devices = devices } }

    func outputDevices() -> [AudioOutputDevice] { lock.withLock { _devices } }
    func selectOutput(id: UInt32) -> Bool {
        lock.withLock {
            guard !_refuse else { return false }
            _selections.append(id)
            for index in _devices.indices { _devices[index].isDefault = _devices[index].id == id }
            return true
        }
    }
}
