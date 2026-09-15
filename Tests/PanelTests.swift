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
        let panel = StatusPanel()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 314, height: 312),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel; window.orderFront(nil)
        defer { window.orderOut(nil) }
        panel.layoutSubtreeIfNeeded()
        let rows = descendants(panel).compactMap { $0 as? StatusRow }
        check(rows.count == 5, "battery and four status rows are controls")
        var opened: [SystemSettings.Page] = []
        panel.onOpenSettings = { opened.append($0) }
        for row in rows {
            check(row.accessibilityRole() == (row.destination == .vpn ? .staticText : .button),
                  "only actionable rows expose a button action")
            check(row.hitTest(NSPoint(x: row.frame.midX, y: row.frame.midY)) === row,
                  "the whole row, including its labels, is clickable")
            row.performClick(nil)
        }
        check(opened == [.battery, .bluetooth, .sound, .focus],
              "actionable rows open their settings and VPN stays read-only")

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
              (wifiMenu.submenu.items.first?.view as? WiFiToggleRowView)?.toggle.state == .off,
              "Wi-Fi off shows only the switch and settings")
        check(wifiMenu.item.subtitle == "已關閉", "the item says Wi-Fi is off")
        L10n.overrideForTesting(nil)
        check(SystemSettings.Page.bluetooth.url.absoluteString == "x-apple.systempreferences:com.apple.BluetoothSettings", "headphones target Bluetooth settings")
        check(SystemSettings.Page.allCases.allSatisfy { $0.url.scheme == "x-apple.systempreferences" },
              "settings links stay within the system settings application")
        print("PASS: native settings actions, read-only VPN, Wi-Fi submenu structure and network routing")
    }
}
