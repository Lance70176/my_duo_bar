import AppKit

@main struct PanelTests {
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
        check(rows.count == 6, "all six status rows are controls")
        var opened: [SystemSettings.Page] = []
        panel.onOpenSettings = { opened.append($0) }
        for row in rows {
            check(row.accessibilityRole() == (row.destination == .vpn ? .staticText : .button),
                  "only actionable rows expose a button action")
            check(row.hitTest(NSPoint(x: row.frame.midX, y: row.frame.midY)) === row,
                  "the whole row, including its labels, is clickable")
            row.performClick(nil)
        }
        check(opened == [.wifi, .battery, .soundOutput, .sound, .focus],
              "actionable rows open their settings and VPN stays read-only")
        var wired = SystemStatus(); wired.wifi.route = .ethernet
        panel.update(wired); rows[0].performClick(nil)
        check(opened.last == .network, "an Ethernet connection opens network settings")
        var wireless = wired; wireless.wifi.associated = true
        panel.update(wireless); rows[0].performClick(nil)
        check(opened.last == .wifi, "an associated Wi-Fi connection opens Wi-Fi settings")
        check(SystemSettings.Page.soundOutput.url.query == "output", "headphones target sound output")
        check(SystemSettings.Page.allCases.allSatisfy { $0.url.scheme == "x-apple.systempreferences" },
              "settings links stay within the system settings application")
        print("PASS: five native settings actions, read-only VPN, accessibility and network routing")
    }
}
