import AppKit

/// The Battery item in the status menu and its submenu: the charge limit switch, the levels macOS offers,
/// the battery's health, the power adapter with a power chart, and Battery Settings. The limit is the system's own (System Settings → Battery), so it stays in effect
/// after this app quits and shows the same value everywhere.
@MainActor
final class BatteryMenuController: NSObject, NSMenuDelegate {
    static let rowWidth: CGFloat = 290
    static let levelKey = "chargeLimitLevel"
    static let defaultLevel = 80
    /// The health is re-read at most this often; it changes slowly and the read runs a helper process.
    static let healthInterval: TimeInterval = 300

    let item = NSMenuItem()
    let submenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Called after the limit changes so the status monitor re-reads the battery.
    var onChargeLimitChanged: (() -> Void)?
    /// Runs the PowerUI calls. Replaceable in tests so the Mac's real limit is never touched.
    var service: ChargeLimitServing = SystemChargeLimitService()
    /// Reads the health figures. Replaceable in tests so no helper process runs.
    var healthService: BatteryHealthReading = SystemBatteryHealthService()

    let limitRow = SwitchRowView(width: BatteryMenuController.rowWidth)
    private let header = NSMenuItem.sectionHeader(title: "")
    private let limitItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let healthHeader = NSMenuItem.sectionHeader(title: "")
    private let capacityItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cyclesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let healthSeparator = NSMenuItem.separator()
    private let settings = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Samples the adapter and battery power for the chart and the CSV log.
    let powerLog: PowerLogger
    let chart = PowerChartView(width: BatteryMenuController.rowWidth)
    private let powerHeader = NSMenuItem.sectionHeader(title: "")
    private let adapterItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let inputItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let flowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let chartItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let historyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// The power history window, made on first use.
    private(set) var history: PowerHistoryWindowController?
    private let powerSeparator = NSMenuItem.separator()
    private let defaults: UserDefaults
    private(set) var health: BatteryHealth?
    private var healthLoaded = false
    private var healthReadAt: Date?
    private let worker = DispatchQueue(label: "com.rex.myduobar.battery", qos: .userInitiated)
    private(set) var state: ChargeLimitState?
    private var battery = BatteryState()
    private var submenuOpen = false
    private var writing = false

    init(defaults: UserDefaults = .standard, powerLog: PowerLogger = PowerLogger()) {
        self.defaults = defaults
        self.powerLog = powerLog
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        item.submenu = submenu
        limitRow.onToggle = { [weak self] in self?.toggleLimit() }
        // Items are created once: a view moved to a new menu item is no longer drawn.
        submenu.addItem(header)
        limitItem.view = limitRow
        submenu.addItem(limitItem)
        submenu.addItem(.separator())
        // Read-only figures, grey like the power source line in the system's own battery menu.
        capacityItem.isEnabled = false
        cyclesItem.isEnabled = false
        submenu.addItem(healthHeader)
        submenu.addItem(capacityItem)
        submenu.addItem(cyclesItem)
        submenu.addItem(healthSeparator)
        for item in [adapterItem, inputItem, flowItem] { item.isEnabled = false }
        chartItem.view = chart
        historyItem.target = self; historyItem.action = #selector(showPowerHistory)
        chart.onClick = { [weak self] in self?.showPowerHistory() }
        chart.toolTip = nil
        for item in [powerHeader, adapterItem, inputItem, flowItem, chartItem, historyItem, powerSeparator] { submenu.addItem(item) }
        powerLog.onSample = { [weak self] in
            guard let self else { return }
            self.refreshPower()
            if let latest = self.powerLog.latest { self.history?.add(latest) }
        }
        settings.target = self; settings.action = #selector(openBatterySettings)
        submenu.addItem(settings)
        update(status: SystemStatus())
    }

    /// The level the switch turns the limit on at: the last one used here or in System Settings.
    var preferredLevel: Int {
        let stored = defaults.integer(forKey: Self.levelKey)
        let levels = state?.levels ?? []
        if levels.contains(stored) { return stored }
        if levels.contains(Self.defaultLevel) { return Self.defaultLevel }
        return levels.first ?? (stored > 0 ? stored : Self.defaultLevel)
    }

    static func symbol(_ battery: BatteryState) -> String {
        guard battery.present else { return "powerplug" }
        if battery.charging { return "battery.100percent.bolt" }
        switch battery.percent ?? 100 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    func update(status: SystemStatus) {
        battery = status.battery
        item.title = L10n.battery
        item.subtitle = battery.present ? battery.title + " · " + battery.detail : battery.detail
        item.image = NSImage(systemSymbolName: Self.symbol(battery), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        item.setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        // The limit can change in System Settings; follow it while the submenu is visible.
        if submenuOpen { reload() }
    }

    /// Called when the status menu opens, so the rows are current before the submenu appears.
    func prepare() { reload(); reloadHealth() }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        submenuOpen = true
        rebuild()
        reload()
        reloadHealth()
        powerLog.sample()
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === submenu { submenuOpen = false }
    }

    func reload() {
        let service = self.service
        worker.async { [weak self] in
            let fresh = service.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(fresh) } }
        }
    }

    /// Re-reads the health unless the last read is recent. Runs on its own queue so a slow helper
    /// never delays the charge limit rows.
    func reloadHealth(force: Bool = false) {
        if !force, let healthReadAt, Date().timeIntervalSince(healthReadAt) < Self.healthInterval { return }
        healthReadAt = Date()
        let service = healthService
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fresh = service.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(health: fresh) } }
        }
    }

    /// Takes a fresh health read; nil means the Mac has no built-in battery and the section hides.
    func apply(health fresh: BatteryHealth?) {
        health = fresh
        healthLoaded = true
        refreshRows()
    }

    /// The health rows: maximum capacity and cycle count.
    var healthItems: [NSMenuItem] { [capacityItem, cyclesItem] }

    /// Takes a fresh read. A write in progress owns the rows until it settles.
    func apply(_ fresh: ChargeLimitState) {
        guard !writing else { return }
        let levelsChanged = fresh.levels != state?.levels || fresh.supported != state?.supported
        state = fresh
        if fresh.enabled, fresh.levels.contains(fresh.limit) { defaults.set(fresh.limit, forKey: Self.levelKey) }
        if submenuOpen, levelsChanged { rebuildLevels() }
        refreshRows()
    }

    /// Re-titles every row in the current language, rebuilds the level rows and refreshes their state.
    func rebuild() {
        header.title = L10n.chargeLimit
        limitItem.title = L10n.chargeLimit
        healthHeader.title = L10n.batteryHealth
        powerHeader.title = L10n.powerAdapter
        historyItem.title = L10n.powerHistoryMenu
        history?.applyTitles()
        settings.title = L10n.batterySettingsMenu
        rebuildLevels()
        refreshRows()
        refreshPower()
    }

    /// Replaces the level rows in place; the switch row keeps its item.
    private func rebuildLevels() {
        for item in levelItems { submenu.removeItem(item) }
        guard let anchor = submenu.items.firstIndex(where: { $0.view === limitRow }) else { return }
        for (offset, level) in (state?.levels ?? []).enumerated() {
            let title = L10n.chargeLimitLevel(level)
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.representedObject = NSNumber(value: level)
            // A view, not a plain item, so picking a level keeps the menu open.
            let choice = ChoiceRowView(width: Self.rowWidth, title: title)
            choice.onSelect = { [weak self] in self?.setLimit(level) }
            row.view = choice
            submenu.insertItem(row, at: anchor + 1 + offset)
        }
    }

    /// The level rows' views, in the order macOS offers them.
    var levelRows: [ChoiceRowView] { levelItems.compactMap { $0.view as? ChoiceRowView } }

    /// The level rows, in the order macOS offers them.
    var levelItems: [NSMenuItem] { submenu.items.filter { $0.representedObject is NSNumber } }

    private func refreshRows() {
        let current = state
        let active = current?.activeLimit
        let detail: String
        if current == nil { detail = L10n.reading }
        else if current?.supported == false { detail = L10n.chargeLimitUnsupported }
        else if let active, current?.setElsewhere == true {
            // Another app's limit at or below the current level is how it pauses charging (AlDente's heat protection).
            let paused = (battery.percent ?? 0) >= active
            detail = paused ? L10n.chargeLimitPausedElsewhere(active) : L10n.chargeLimitSetElsewhere(active)
        }
        else if let active { detail = L10n.chargeLimitOn(active) }
        else { detail = L10n.chargeLimitOff }
        limitRow.configure(symbol: active != nil ? "battery.75percent" : "battery.100percent", title: L10n.chargeLimit, detail: detail,
                           isOn: active != nil, isEnabled: current?.supported == true && !writing, help: L10n.chargeLimitToggle)
        for row in levelItems {
            let level = (row.representedObject as? NSNumber)?.intValue
            let enabled = current?.supported == true && !writing
            row.isEnabled = enabled
            if let choice = row.view as? ChoiceRowView {
                choice.isChecked = level == active
                choice.isEnabled = enabled
            }
        }
        let noBattery = healthLoaded && health == nil
        for item in [healthHeader, capacityItem, healthSeparator] { item.isHidden = noBattery }
        capacityItem.title = health?.capacityLine ?? L10n.reading
        cyclesItem.title = health?.cycleLine ?? ""
        cyclesItem.isHidden = noBattery || health == nil
    }

    /// The power section's rows: rating, live input, battery and system power, the chart and the log.
    var powerItems: [NSMenuItem] { [adapterItem, inputItem, flowItem, chartItem, historyItem] }

    /// Shows the latest power reading. The section hides on a Mac without a built-in battery.
    func refreshPower() {
        let latest = powerLog.latest
        let absent = powerLog.loaded && latest == nil
        for item in powerItems + [powerHeader, powerSeparator] { item.isHidden = absent }
        if let latest, let rated = latest.adapterWatts {
            adapterItem.title = L10n.adapterRated(rated, volts: latest.adapterVolts, amps: latest.adapterAmps)
            inputItem.title = L10n.adapterInput(latest.inputWatts, volts: latest.inputVolts, amps: latest.inputAmps)
        } else {
            adapterItem.title = latest == nil ? L10n.reading : L10n.noPowerAdapter
            inputItem.isHidden = true
        }
        flowItem.title = latest.map { L10n.powerFlow(battery: $0.batteryWatts, system: $0.systemWatts) } ?? ""
        if latest == nil { flowItem.isHidden = true }
        chart.samples = powerLog.samples
    }

    /// Opens the power history window: the whole log on a chart that pans and zooms.
    @objc func showPowerHistory() {
        closeMenus()
        let window = history ?? PowerHistoryWindowController(fileURL: powerLog.fileURL)
        history = window
        // After the menu has closed, so the window can become key.
        DispatchQueue.main.async { window.present(recent: self.powerLog.samples) }
    }

    private func closeMenus() {
        var root: NSMenu? = submenu
        while let parent = root?.supermenu { root = parent }
        root?.cancelTracking()
    }

    @objc private func openBatterySettings() {
        closeMenus()
        onOpenSettings?(.battery)
    }

    /// Turns the limit off, or on at the preferred level.
    func toggleLimit() {
        guard let state, state.supported else { return }
        setLimit(state.activeLimit == nil ? preferredLevel : nil)
    }

    /// Sets the limit (nil turns it off), keeps the menu open and re-reads what macOS took.
    /// If macOS refuses, Battery settings opens instead.
    func setLimit(_ level: Int?) {
        guard var local = state, local.supported, !writing else { return }
        writing = true
        local.enabled = level != nil
        local.limit = level ?? 100
        state = local
        refreshRows()
        let service = self.service
        worker.async { [weak self] in
            let accepted = level.map { service.setLimit($0) } ?? service.disable()
            let fresh = service.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.writing = false
                    self.apply(fresh)
                    if accepted {
                        self.onChargeLimitChanged?()
                    } else {
                        self.closeMenus()
                        self.onOpenSettings?(.battery)
                    }
                }
            }
        }
    }
}
