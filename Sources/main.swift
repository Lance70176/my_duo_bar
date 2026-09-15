import AppKit
import ServiceManagement
import Intents

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private let panelHeader = StatusPanelHeader()
    private let batteryMenu = BatteryMenuController()
    private let focusPanel = StatusPanel()
    private let wifiMenu = WiFiMenuController()
    private let vpnMenu = VPNMenuController()
    private let outputMenu = OutputMenuController()
    private let soundMenu = SoundMenuController()
    private let monitor = SystemMonitor()
    private let preferences = DotPreferences()
    private let canvas = StatusIconView()
    private var settings: SettingsController?
    private let systemIconsItem = NSMenuItem(title: "", action: #selector(openSystemIcons), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "", action: #selector(showSettings), keyEquivalent: ",")
    private let quitItem = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: 36)
        item.autosaveName = "MyDuoBar"
        item.isVisible = true
        if let button = item.button {
            // Reserve the full drawing height; AppKit sizes the status item to this image.
            button.image = NSImage(size: DuoIcon.size)
            button.imagePosition = .imageOnly
            canvas.frame = button.bounds
            canvas.autoresizingMask = [.width, .height]
            button.addSubview(canvas)
        }
        let openSettings: (SystemSettings.Page) -> Void = { [weak self] page in
            self?.menu.cancelTracking()
            DispatchQueue.main.async { SystemSettings.open(page) }
        }
        batteryMenu.onOpenSettings = openSettings
        focusPanel.onOpenSettings = openSettings
        wifiMenu.onOpenSettings = openSettings
        vpnMenu.onOpenSettings = openSettings
        outputMenu.onOpenSettings = openSettings
        soundMenu.onOpenSettings = openSettings
        outputMenu.onOutputChanged = { [weak self] in self?.monitor.refresh() }
        batteryMenu.onChargeLimitChanged = { [weak self] in self?.monitor.refresh() }
        wifiMenu.onWiFiChanged = { [weak self] in self?.monitor.refresh() }
        vpnMenu.onVPNChanged = { [weak self] in self?.monitor.refresh() }
        menu.delegate = self
        menu.autoenablesItems = false
        let header = NSMenuItem(); header.view = panelHeader; menu.addItem(header)
        menu.addItem(wifiMenu.item)
        menu.addItem(batteryMenu.item)
        menu.addItem(vpnMenu.item)
        menu.addItem(outputMenu.item)
        menu.addItem(soundMenu.item)
        let focus = NSMenuItem(); focus.view = focusPanel; menu.addItem(focus)
        menu.addItem(.separator())
        for menuItem in [systemIconsItem, settingsItem, quitItem] {
            menuItem.target = self; menu.addItem(menuItem)
        }
        applyMenuTitles()
        item.menu = menu
        monitor.onChange = { [weak self] state in
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
        if CommandLine.arguments.contains("--request-focus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                INFocusStatusCenter.default.requestAuthorization { _ in
                    DispatchQueue.main.async { self?.monitor.refresh() }
                }
            }
        }
        if CommandLine.arguments.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.item.button?.performClick(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return false
    }
    private func applyMenuTitles() {
        systemIconsItem.title = L10n.hideSystemIcons
        settingsItem.title = L10n.settingsMenu
        quitItem.title = L10n.quit
    }

    /// Re-render everything that holds text; the refresh rebuilds status strings in the new language.
    private func languageDidChange() {
        applyMenuTitles()
        panelHeader.update()
        updateMenuRows(monitor.status)
        item.button?.setAccessibilityLabel(monitor.status.accessibilitySummary)
        settings?.update(monitor.status)
        monitor.refresh()
    }

    private func updateMenuRows(_ state: SystemStatus) {
        batteryMenu.update(status: state)
        wifiMenu.update(status: state)
        vpnMenu.update(status: state)
        outputMenu.update(status: state)
        soundMenu.update(status: state)
        focusPanel.update(state)
    }

    private func update(_ state: SystemStatus) {
        renderIcon()
        item.button?.setAccessibilityLabel(state.accessibilitySummary)
        // Deliberately no tracking area or hover expansion.
        updateMenuRows(state)
        settings?.update(state)
    }
    func menuWillOpen(_ menu: NSMenu) {
        canvas.animateTurn()
        updateMenuRows(monitor.status)
        wifiMenu.prepare()
        batteryMenu.prepare()
        vpnMenu.prepare()
        outputMenu.prepare()
        soundMenu.prepare()
        monitor.setMenuOpen(true)
    }
    func menuDidClose(_ menu: NSMenu) { monitor.setMenuOpen(false) }

    private func renderIcon() {
        canvas.update(monitor.status, layout: preferences.layout)
    }

    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsController(preferences: preferences)
            controller.onRefresh = { [weak self] in self?.monitor.refresh() }
            controller.onLanguageChange = { [weak self] in self?.languageDidChange() }
            settings = controller
        }
        settings?.present(status: monitor.status)
    }
    @objc private func openSystemIcons() { SystemSettings.open(.menubar) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { canvas.stopAnimations(); monitor.stop() }
}

if CommandLine.arguments.contains("--diagnose") {
    let status = SystemStatus(battery: SystemReaders.battery(),
                              wifi: SystemReaders.wifi(client: .shared(), route: .unknown),
                              vpn: SystemReaders.vpn(), audio: SystemReaders.audio(), focus: SystemReaders.focus())
    let report: [String: Any] = [
        "batteryPresent": status.battery.present,
        "batteryCharging": status.battery.charging,
        "lowPowerMode": status.battery.lowPowerMode,
        "externalPower": status.battery.externalPower,
        "powerRingGreen": status.battery.connectedToPower && !status.battery.lowPowerMode,
        "batteryPercent": status.battery.percent as Any? ?? NSNull(),
        "chargeLimit": status.battery.chargeLimit as Any? ?? NSNull(),
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
        "focusAuthorization": INFocusStatusCenter.default.authorizationStatus.rawValue,
        "focusSharedValue": INFocusStatusCenter.default.focusStatus.isFocused as Any? ?? NSNull(),
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
