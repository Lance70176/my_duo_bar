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
        inputChecks()
        bluetoothChecks()
        batteryChecks()
        L10n.overrideForTesting(nil)
        check(SystemSettings.Page.bluetooth.url.absoluteString == "x-apple.systempreferences:com.apple.BluetoothSettings", "the Bluetooth submenu targets Bluetooth settings")
        check(SystemSettings.Page.allCases.allSatisfy { $0.url.scheme == "x-apple.systempreferences" },
              "settings links stay within the system settings application")
        print("PASS: native settings actions, Wi-Fi, Battery, VPN, Bluetooth and Sound submenus, custom controls and network routing")
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
    /// Exercises the output device list in the Sound submenu against fake devices: the real default output is never changed.
    static func outputChecks() {
        let speakers = AudioOutputDevice(id: 1, name: "MacBook Pro 喇叭", symbol: "speaker.wave.2.fill", isHeadphone: false, isDefault: true)
        let airpods = AudioOutputDevice(id: 2, name: "AirPods Pro", symbol: "airpodspro", isHeadphone: true, isDefault: false)
        let fake = FakeOutputDeviceService([speakers, airpods])
        let sound = SoundMenuController()
        sound.service = FakeSoundService(SoundOutput(name: "MacBook Pro 喇叭", volume: 0.5, muted: false, canSetVolume: true, canSetMute: true))
        sound.outputService = fake
        sound.inputService = FakeInputDeviceService([])
        var opened: [SystemSettings.Page] = []
        var changes = 0
        sound.onOpenSettings = { opened.append($0) }
        sound.onOutputChanged = { changes += 1 }
        sound.update(status: SystemStatus())

        sound.menuWillOpen(sound.submenu)
        spin(0.2)
        let items = { sound.submenu.items }
        let rows = { items().filter { $0.representedObject is NSNumber && $0.tag == 7 } }
        let header = items().firstIndex { $0.isSectionHeader && $0.title == "輸出裝置" }
        check(header != nil && items()[1].view === sound.volumeRow && items()[2].view === sound.muteRow
              && items()[header! - 1].isSeparatorItem && items().last?.title == "聲音設定…",
              "the Sound submenu lists output devices under their own header, after the slider and mute row")
        check(rows().map(\.title) == ["MacBook Pro 喇叭", "AirPods Pro"] && rows().map(\.state) == [.on, .off] && rows().allSatisfy { $0.image != nil }
              && items().firstIndex(of: rows()[0]) == header! + 1,
              "every output device is listed with an icon right after the header, with the current one checked")

        rows()[1].target.map { _ = ($0 as? NSObject)?.perform(rows()[1].action, with: rows()[1]) }
        spin(0.2)
        check(fake.selections == [2] && rows().map(\.state) == [.off, .on] && changes == 1, "choosing a device makes it the default output")
        check(items()[1].view === sound.volumeRow && items()[2].view === sound.muteRow, "replacing device rows keeps the slider and mute row")
        sound.select(id: 2)
        spin(0.1)
        check(fake.selections == [2], "choosing the current device does nothing")

        fake.refuse = true
        sound.select(id: 1)
        spin(0.2)
        check(opened == [.sound] && rows().map(\.state) == [.off, .on], "a refused switch opens Sound settings and keeps the check")

        fake.replace([speakers])
        sound.update(status: SystemStatus())
        spin(0.2)
        check(rows().map(\.title) == ["MacBook Pro 喇叭"], "a device that disconnects leaves the open submenu")
        fake.replace([])
        sound.reloadDevices()
        spin(0.2)
        check(rows().isEmpty && items()[header! + 1].title == "沒有可用的輸出裝置" && !items()[header! + 1].isEnabled,
              "no devices shows a note in place of the rows")
        sound.menuDidClose(sound.submenu)

        check(AudioOutputDevice.symbol(name: "AirPods Max", transport: nil, headphone: true) == "airpodsmax"
              && AudioOutputDevice.symbol(name: "LG HDR 4K", transport: kAudioDeviceTransportTypeHDMI, headphone: false) == "tv"
              && AudioOutputDevice.symbol(name: "Sony WH-1000XM5", transport: kAudioDeviceTransportTypeBluetooth, headphone: true) == "headphones",
              "device icons follow the device kind")
    }

    /// Exercises the input device list in the Sound submenu against fake devices: the real default input is never changed.
    static func inputChecks() {
        let builtIn = AudioInputDevice(id: 11, name: "MacBook Pro 麥克風", symbol: "mic.fill", isDefault: true)
        let airpods = AudioInputDevice(id: 12, name: "AirPods Pro", symbol: "airpodspro", isDefault: false)
        let speakers = AudioOutputDevice(id: 1, name: "MacBook Pro 喇叭", symbol: "speaker.wave.2.fill", isHeadphone: false, isDefault: true)
        let fake = FakeInputDeviceService([builtIn, airpods])
        let sound = SoundMenuController()
        sound.service = FakeSoundService(SoundOutput(name: "MacBook Pro 喇叭", volume: 0.5, muted: false, canSetVolume: true, canSetMute: true))
        sound.outputService = FakeOutputDeviceService([speakers])
        sound.inputService = fake
        var opened: [SystemSettings.Page] = []
        var changes = 0
        sound.onOpenSettings = { opened.append($0) }
        sound.onOutputChanged = { changes += 1 }
        sound.update(status: SystemStatus())

        sound.menuWillOpen(sound.submenu)
        spin(0.2)
        let items = { sound.submenu.items }
        let outputHeader = items().firstIndex { $0.isSectionHeader && $0.title == "輸出裝置" }
        let header = items().firstIndex { $0.isSectionHeader && $0.title == "輸入裝置" }
        let rows = { items().filter { $0.representedObject is NSNumber && $0.tag == 8 } }
        check(outputHeader != nil && header != nil && header! > outputHeader! && items()[header! - 1].isSeparatorItem
              && items().last?.title == "聲音設定…" && items()[items().count - 2].isSeparatorItem,
              "the Sound submenu lists input devices under their own header, after the output devices and before Sound Settings")
        check(rows().map(\.title) == ["MacBook Pro 麥克風", "AirPods Pro"] && rows().map(\.state) == [.on, .off] && rows().allSatisfy { $0.image != nil }
              && items().firstIndex(of: rows()[0]) == header! + 1,
              "every input device is listed with an icon right after the header, with the current one checked")
        check(items()[outputHeader! + 1].title == "MacBook Pro 喇叭" && items()[outputHeader! + 2].isSeparatorItem,
              "output rows stay in their own section")

        rows()[1].target.map { _ = ($0 as? NSObject)?.perform(rows()[1].action, with: rows()[1]) }
        spin(0.2)
        check(fake.selections == [12] && rows().map(\.state) == [.off, .on] && changes == 0 && opened.isEmpty,
              "choosing a device makes it the default input without touching the output")
        check(items()[1].view === sound.volumeRow && items()[2].view === sound.muteRow
              && items()[outputHeader! + 1].title == "MacBook Pro 喇叭", "replacing input rows keeps the slider, mute row and output rows")
        sound.selectInput(id: 12)
        spin(0.1)
        check(fake.selections == [12], "choosing the current input does nothing")

        fake.refuse = true
        sound.selectInput(id: 11)
        spin(0.2)
        check(opened == [.sound] && rows().map(\.state) == [.off, .on], "a refused input switch opens Sound settings and keeps the check")

        fake.replace([])
        sound.reloadInputs()
        spin(0.2)
        check(rows().isEmpty && items()[header! + 1].title == "沒有可用的輸入裝置" && !items()[header! + 1].isEnabled,
              "no inputs shows a note in place of the rows")
        sound.menuDidClose(sound.submenu)

        check(AudioInputDevice.symbol(name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth) == "airpodspro"
              && AudioInputDevice.symbol(name: "MacBook Pro 麥克風", transport: kAudioDeviceTransportTypeBuiltIn) == "mic.fill"
              && AudioInputDevice.symbol(name: "Sony WH-1000XM5", transport: kAudioDeviceTransportTypeBluetooth) == "headphones"
              && AudioInputDevice.symbol(name: "BlackHole 2ch", transport: kAudioDeviceTransportTypeVirtual) == "waveform",
              "input icons follow the device kind")
    }

    /// Exercises the Bluetooth submenu against fake devices: nothing real is connected or disconnected.
    static func bluetoothChecks() {
        let airpods = BluetoothDevice(id: "aa-bb", name: "AirPods Pro", symbol: "airpodspro", status: .connected,
                                      battery: .earbuds(left: 100, right: 90, case: 86))
        let keyboard = BluetoothDevice(id: "cc-dd", name: "Magic Keyboard", symbol: "keyboard", status: .disconnected, battery: .single(81))
        check(BluetoothBattery.single(95).summary == "95%" && BluetoothBattery.single(95).brief == "95%"
              && airpods.battery?.summary == "左 100% · 右 90% · 盒 86%" && airpods.battery?.brief == "90%"
              && BluetoothBattery.earbuds(left: nil, right: nil, case: 50).brief == "50%"
              && BluetoothBattery.earbuds(left: nil, right: nil, case: nil).brief == "",
              "battery levels read as one figure, or the buds and case")
        check(keyboard.detail == "未連線" && keyboard.listing == "Magic Keyboard", "a disconnected device shows no level")
        let fake = FakeBluetoothService(BluetoothState(powered: true, devices: [airpods, keyboard]))
        let bluetooth = BluetoothMenuController()
        bluetooth.service = fake
        var opened: [SystemSettings.Page] = []
        var changes = 0
        bluetooth.onOpenSettings = { opened.append($0) }
        bluetooth.onBluetoothChanged = { changes += 1 }
        check(bluetooth.item.submenu === bluetooth.submenu && bluetooth.item.title == "藍牙" && bluetooth.item.subtitle == "讀取中"
              && bluetooth.item.image != nil, "Bluetooth opens a submenu and shows the Bluetooth glyph")

        bluetooth.menuWillOpen(bluetooth.submenu)
        spin(0.2)
        check(bluetooth.item.subtitle == "AirPods Pro 90%", "the item lists the connected devices with their levels")
        let rows = { bluetooth.submenu.items.compactMap { $0.view as? BluetoothRowView } }
        check(bluetooth.submenu.items.first?.isSectionHeader == true && bluetooth.submenu.items.first?.title == "裝置"
              && bluetooth.submenu.items.last?.title == "藍牙設定…", "the submenu has a Devices header and ends with Bluetooth Settings")
        check(rows().map(\.device.name) == ["AirPods Pro", "Magic Keyboard"] && rows().map(\.toggleSwitch.isOn) == [true, false]
              && rows().map(\.detailText) == ["已連線 · 左 100% · 右 90% · 盒 86%", "未連線"] && rows()[0].symbolName == "airpodspro",
              "every paired device has a row with its icon, state and switch")

        rows()[1].onToggle?()
        check(rows()[1].detailText == "連線中…" && rows()[1].toggleSwitch.isOn && !rows()[1].toggleSwitch.isEnabled,
              "toggling a device shows Connecting and locks its switch")
        spin(0.3)
        check(fake.calls == ["connect cc-dd"] && rows()[1].detailText == "已連線 · 81%" && rows()[1].toggleSwitch.isEnabled && changes == 1
              && bluetooth.item.subtitle == "AirPods Pro 90%、Magic Keyboard 81%", "a connected device settles and the item follows with its level")

        rows()[0].onToggle?()
        check(rows()[0].detailText == "正在中斷…", "toggling a connected device shows Disconnecting")
        spin(0.3)
        check(fake.calls.last == "disconnect aa-bb" && rows()[0].detailText == "未連線" && !rows()[0].toggleSwitch.isOn && changes == 2,
              "a disconnected device settles")

        fake.refuse = true
        rows()[0].onToggle?()
        spin(0.3)
        check(opened == [.bluetooth] && rows()[0].detailText == "未連線" && !rows()[0].toggleSwitch.isOn,
              "a refused connection opens Bluetooth settings and keeps the row off")

        fake.replace(BluetoothState(powered: true, devices: [BluetoothDevice(id: "cc-dd", name: "Magic Keyboard", symbol: "keyboard", status: .connected)]))
        bluetooth.reload()
        spin(0.2)
        check(rows().map(\.device.name) == ["Magic Keyboard"], "a device that is unpaired leaves the open submenu")

        fake.replace(BluetoothState(powered: false))
        bluetooth.reload()
        spin(0.2)
        check(rows().isEmpty && bluetooth.submenu.items[1].title == "藍牙已關閉" && !bluetooth.submenu.items[1].isEnabled
              && bluetooth.item.subtitle == "已關閉", "Bluetooth off shows a note instead of devices")
        fake.replace(.unavailable)
        bluetooth.reload()
        spin(0.2)
        check(bluetooth.item.subtitle == "此 Mac 沒有藍牙", "a Mac without Bluetooth says so")

        L10n.overrideForTesting(.en)
        bluetooth.rebuild()
        check(bluetooth.submenu.items.last?.title == "Bluetooth Settings…" && bluetooth.item.subtitle == "Bluetooth Unavailable"
              && airpods.battery?.summary == "L 100% · R 90% · Case 86%", "the Bluetooth submenu follows the app language")
        L10n.overrideForTesting(.zhHant)
        bluetooth.menuDidClose(bluetooth.submenu)

        check(BluetoothDevice.symbol(name: "AirPods Max", major: 4, minor: 6) == "airpodsmax"
              && BluetoothDevice.symbol(name: "WH-1000XM5", major: 4, minor: 6) == "headphones"
              && BluetoothDevice.symbol(name: "Boom", major: 4, minor: 5) == "hifispeaker.fill"
              && BluetoothDevice.symbol(name: "Magic Mouse", major: 5, minor: 0x20) == "computermouse.fill"
              && BluetoothDevice.symbol(name: "Keyboard", major: 5, minor: 0x10) == "keyboard"
              && BluetoothDevice.symbol(name: "Pad", major: 5, minor: 0x02) == "gamecontroller.fill"
              && BluetoothDevice.symbol(name: "iPhone", major: 2, minor: 0) == "iphone",
              "Bluetooth device icons follow the device class")
        let sorted = BluetoothService.sorted([keyboard, airpods])
        check(sorted.map(\.name) == ["AirPods Pro", "Magic Keyboard"], "connected devices are listed first")
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
        let limitItem = menu.submenu.items[1]
        check(menu.levelItems.isEmpty, "before the first read the submenu has no level rows yet")
        spin(0.2)
        check(menu.submenu.items[1] === limitItem && limitItem.view === menu.limitRow,
              "levels arriving after the submenu opened are inserted without re-adding the switch row")
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

/// In-memory input devices for tests.
final class FakeInputDeviceService: InputDeviceServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [AudioInputDevice]
    private var _selections: [UInt32] = []
    private var _refuse = false
    init(_ devices: [AudioInputDevice]) { _devices = devices }

    var selections: [UInt32] { lock.withLock { _selections } }
    var refuse: Bool { get { lock.withLock { _refuse } } set { lock.withLock { _refuse = newValue } } }
    func replace(_ devices: [AudioInputDevice]) { lock.withLock { _devices = devices } }

    func inputDevices() -> [AudioInputDevice] { lock.withLock { _devices } }
    func selectInput(id: UInt32) -> Bool {
        lock.withLock {
            guard !_refuse else { return false }
            _selections.append(id)
            for index in _devices.indices { _devices[index].isDefault = _devices[index].id == id }
            return true
        }
    }
}

/// In-memory Bluetooth devices for tests. Connects and disconnects settle on the first poll.
final class FakeBluetoothService: BluetoothServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: BluetoothState
    private var _calls: [String] = []
    private var _refuse = false
    init(_ state: BluetoothState) { _state = state }

    var pollInterval: TimeInterval { 0.01 }
    var calls: [String] { lock.withLock { _calls } }
    var refuse: Bool { get { lock.withLock { _refuse } } set { lock.withLock { _refuse = newValue } } }
    func replace(_ state: BluetoothState) { lock.withLock { _state = state } }

    func read() -> BluetoothState { lock.withLock { _state } }
    func connect(id: String) -> Bool { set(id, connected: true, call: "connect") }
    func disconnect(id: String) -> Bool { set(id, connected: false, call: "disconnect") }
    private func set(_ id: String, connected: Bool, call: String) -> Bool {
        Thread.sleep(forTimeInterval: 0.05)
        return lock.withLock {
            _calls.append("\(call) \(id)")
            guard !_refuse, let index = _state.devices.firstIndex(where: { $0.id == id }) else { return false }
            _state.devices[index].status = connected ? .connected : .disconnected
            return true
        }
    }
}
