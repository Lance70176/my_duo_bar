import AppKit

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
        for (section, expected) in [(StatusPanel.Section.power, [SystemSettings.Page.battery]),
                                    (.devices, [.bluetooth, .sound, .focus])] {
            let panel = StatusPanel(section: section)
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
            let lowest = descendants(panel).map { $0.convert($0.bounds, to: panel).minY }.min() ?? 0
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
        L10n.overrideForTesting(nil)
        check(SystemSettings.Page.bluetooth.url.absoluteString == "x-apple.systempreferences:com.apple.BluetoothSettings", "headphones target Bluetooth settings")
        check(SystemSettings.Page.allCases.allSatisfy { $0.url.scheme == "x-apple.systempreferences" },
              "settings links stay within the system settings application")
        print("PASS: native settings actions, Wi-Fi and VPN submenus, custom switch and network routing")
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
