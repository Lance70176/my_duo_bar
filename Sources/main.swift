import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private let panel = StatusPanel()
    private let monitor = SystemMonitor()
    private let preferences = DotPreferences()
    private let motion = IconMotion()
    private let canvas = StatusIconView()
    private var settings: SettingsController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: 36)
        item.autosaveName = "DuoBar"
        item.isVisible = true
        if let button = item.button {
            canvas.frame = button.bounds
            canvas.autoresizingMask = [.width, .height]
            button.addSubview(canvas)
        }
        menu.delegate = self
        menu.autoenablesItems = false
        let content = NSMenuItem(); content.view = panel; menu.addItem(content)
        menu.addItem(.separator())
        let systemIcons = NSMenuItem(title: "关闭对应状态栏", action: #selector(openSystemIcons), keyEquivalent: "")
        systemIcons.target = self; menu.addItem(systemIcons)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self; menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "退出 DuoBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        motion.onFrame = { [weak self] in self?.renderIcon() }
        monitor.onChange = { [weak self] state in
            self?.motion.update(state)
            self?.update(state)
        }
        preferences.onChange = { [weak self] in
            guard let self else { return }
            self.update(self.monitor.status)
        }
        update(monitor.status)
        monitor.start()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasShownSetup")
        if firstLaunch { UserDefaults.standard.set(true, forKey: "hasShownSetup") }
        if firstLaunch || CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showSettings() }
        }
        if CommandLine.arguments.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.item.button?.performClick(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return false
    }
    private func update(_ state: SystemStatus) {
        renderIcon()
        item.button?.setAccessibilityLabel(state.accessibilitySummary)
        // Deliberately no tracking area or hover expansion.
        panel.update(state)
        settings?.update(state)
    }
    func menuWillOpen(_ menu: NSMenu) { monitor.setMenuOpen(true) }
    func menuDidClose(_ menu: NSMenu) { monitor.setMenuOpen(false) }

    private func renderIcon() {
        canvas.status = monitor.status
        canvas.dotLayout = preferences.layout
        canvas.presentation = motion.frame
        canvas.needsDisplay = true
    }

    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsController(preferences: preferences)
            controller.onRefresh = { [weak self] in self?.monitor.refresh() }
            settings = controller
        }
        settings?.present(status: monitor.status)
    }
    @objc private func openSystemIcons() { SystemSettings.open("menubar") }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { motion.stop(); monitor.stop() }
}

if CommandLine.arguments.contains("--diagnose") {
    let status = SystemStatus(battery: SystemReaders.battery(),
                              wifi: SystemReaders.wifi(client: .shared(), route: .unknown),
                              vpn: SystemReaders.vpn(), audio: SystemReaders.audio(), focus: SystemReaders.focus())
    let report: [String: Any] = [
        "batteryPresent": status.battery.present,
        "batteryCharging": status.battery.charging,
        "externalPower": status.battery.externalPower,
        "powerRingGreen": status.battery.connectedToPower,
        "batteryPercent": status.battery.percent as Any? ?? NSNull(),
        "wifiAssociated": status.wifi.associated,
        "wifiNameAvailable": status.wifi.ssid != nil,
        "vpnConfirmedCount": status.vpn.names.count,
        "routedVPN": status.vpn.routedTunnel,
        "systemProxy": status.vpn.systemProxy,
        "unidentifiedTunnel": status.vpn.hasUnidentifiedTunnel,
        "headphoneCount": status.audio.headphoneNames.count,
        "muteAvailable": status.audio.muted != nil,
        "muted": status.audio.muted as Any? ?? NSNull(),
        "focus": status.focus.title,
        "activeGlyphCount": status.glyphs.count,
        "loginItemStatus": SMAppService.mainApp.status.rawValue
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    let application = NSApplication.shared
    if CommandLine.arguments.contains("--light") { application.appearance = NSAppearance(named: .aqua) }
    if CommandLine.arguments.contains("--dark") { application.appearance = NSAppearance(named: .darkAqua) }
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
