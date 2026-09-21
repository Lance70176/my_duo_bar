import AppKit

/// The Battery item in the status menu and its submenu: the charge limit switch, the levels macOS offers
/// and Battery Settings. The limit is the system's own (System Settings → Battery), so it stays in effect
/// after this app quits and shows the same value everywhere.
@MainActor
final class BatteryMenuController: NSObject, NSMenuDelegate {
    static let rowWidth: CGFloat = 290
    static let levelKey = "chargeLimitLevel"
    static let defaultLevel = 80

    let item = NSMenuItem()
    let submenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Called after the limit changes so the status monitor re-reads the battery.
    var onChargeLimitChanged: (() -> Void)?
    /// Runs the PowerUI calls. Replaceable in tests so the Mac's real limit is never touched.
    var service: ChargeLimitServing = SystemChargeLimitService()

    let limitRow = SwitchRowView(width: BatteryMenuController.rowWidth)
    private let defaults: UserDefaults
    private let worker = DispatchQueue(label: "com.rex.myduobar.battery", qos: .userInitiated)
    private(set) var state: ChargeLimitState?
    private var battery = BatteryState()
    private var submenuOpen = false
    private var writing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        item.submenu = submenu
        limitRow.onToggle = { [weak self] in self?.toggleLimit() }
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
    func prepare() { reload() }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        submenuOpen = true
        rebuild()
        reload()
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

    /// Takes a fresh read. A write in progress owns the rows until it settles.
    func apply(_ fresh: ChargeLimitState) {
        guard !writing else { return }
        let levelsChanged = fresh.levels != state?.levels || fresh.supported != state?.supported
        state = fresh
        if fresh.enabled, fresh.levels.contains(fresh.limit) { defaults.set(fresh.limit, forKey: Self.levelKey) }
        if submenuOpen, levelsChanged { rebuildLevels() }
        refreshRows()
    }

    func rebuild() {
        submenu.removeAllItems()
        submenu.addItem(NSMenuItem.sectionHeader(title: L10n.chargeLimit))
        let limit = NSMenuItem(title: L10n.chargeLimit, action: nil, keyEquivalent: "")
        limit.view = limitRow
        submenu.addItem(limit)
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.batterySettingsMenu, action: #selector(openBatterySettings), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)
        rebuildLevels()
        refreshRows()
    }

    /// Replaces the level rows in place. The switch row keeps its item: a view removed from an open menu
    /// and added back is no longer drawn, which left a blank space above the levels.
    private func rebuildLevels() {
        for item in levelItems { submenu.removeItem(item) }
        guard let anchor = submenu.items.firstIndex(where: { $0.view === limitRow }) else { return }
        for (offset, level) in (state?.levels ?? []).enumerated() {
            let row = NSMenuItem(title: L10n.chargeLimitLevel(level), action: #selector(chooseLevel(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = NSNumber(value: level)
            row.indentationLevel = 1
            submenu.insertItem(row, at: anchor + 1 + offset)
        }
    }

    /// The level rows, in the order macOS offers them.
    var levelItems: [NSMenuItem] { submenu.items.filter { $0.representedObject is NSNumber } }

    private func refreshRows() {
        let current = state
        let active = current?.activeLimit
        let detail: String
        if current == nil { detail = L10n.reading }
        else if current?.supported == false { detail = L10n.chargeLimitUnsupported }
        else if let active { detail = L10n.chargeLimitOn(active) }
        else { detail = L10n.chargeLimitOff }
        limitRow.configure(symbol: active != nil ? "battery.75percent" : "battery.100percent", title: L10n.chargeLimit, detail: detail,
                           isOn: active != nil, isEnabled: current?.supported == true && !writing, help: L10n.chargeLimitToggle)
        for row in levelItems {
            let level = (row.representedObject as? NSNumber)?.intValue
            row.state = level == active ? .on : .off
            row.isEnabled = current?.supported == true && !writing
        }
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

    @objc private func chooseLevel(_ sender: NSMenuItem) {
        guard let level = (sender.representedObject as? NSNumber)?.intValue else { return }
        setLimit(level)
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
