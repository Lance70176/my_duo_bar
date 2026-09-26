import AppKit

/// The Keep Awake item in the status menu and its submenu: a switch, how long to stay awake, and whether
/// the display stays on too. Built on power assertions, so nothing outlives the app: quitting releases
/// the hold and the next launch starts with it off.
@MainActor
final class SleepMenuController: NSObject, NSMenuDelegate {
    static let rowWidth: CGFloat = 290
    static let minutesKey = "keepAwakeMinutes"
    static let displayKey = "keepAwakeDisplay"
    /// Choices in minutes; 0 keeps the Mac awake until the switch is turned off.
    static let durations = [0, 30, 60, 120, 240]
    /// While the submenu is open, the remaining time is refreshed this often.
    static let tickInterval: TimeInterval = 15

    let item = NSMenuItem()
    let submenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Creates and releases the power assertions. Replaceable in tests so the Mac's sleep is never touched.
    var service: SleepGuarding = SystemSleepService()

    let guardRow = SwitchRowView(width: SleepMenuController.rowWidth)
    private let defaults: UserDefaults
    private(set) var isOn = false
    /// When a timed hold ends; nil while off or while holding until turned off.
    private(set) var until: Date?
    private var expiry: Timer?
    private var ticker: Timer?
    private var submenuOpen = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        item.submenu = submenu
        guardRow.onToggle = { [weak self] in self?.toggle() }
        rebuild()
    }

    /// The chosen duration in minutes; 0 means until turned off.
    var minutes: Int {
        let stored = defaults.integer(forKey: Self.minutesKey)
        return Self.durations.contains(stored) ? stored : 0
    }
    var keepsDisplayOn: Bool { defaults.bool(forKey: Self.displayKey) }

    /// Re-renders the text, e.g. after a language change.
    func refresh() { refreshRows() }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        submenuOpen = true
        rebuild()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRows() }
        }
        RunLoop.main.add(ticker!, forMode: .eventTracking)
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === submenu else { return }
        submenuOpen = false
        ticker?.invalidate()
        ticker = nil
    }

    func rebuild() {
        submenu.removeAllItems()
        submenu.addItem(NSMenuItem.sectionHeader(title: L10n.keepAwake))
        let row = NSMenuItem(title: L10n.keepAwake, action: nil, keyEquivalent: "")
        row.view = guardRow
        submenu.addItem(row)
        for minutes in Self.durations {
            let choice = NSMenuItem(title: minutes == 0 ? L10n.untilTurnedOff : L10n.keepAwakeFor(minutes),
                                    action: #selector(chooseDuration(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = NSNumber(value: minutes)
            choice.indentationLevel = 1
            submenu.addItem(choice)
        }
        submenu.addItem(.separator())
        let display = NSMenuItem(title: L10n.keepDisplayOn, action: #selector(toggleDisplay), keyEquivalent: "")
        display.target = self
        submenu.addItem(display)
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.batterySettingsMenu, action: #selector(openBatterySettings), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)
        refreshRows()
    }

    /// The duration rows, in the order offered.
    var durationItems: [NSMenuItem] { submenu.items.filter { $0.representedObject is NSNumber } }
    var displayItem: NSMenuItem? { submenu.items.first { $0.action == #selector(toggleDisplay) } }

    /// The status line: off, on until turned off, or on with the time left.
    var detail: String {
        guard isOn else { return L10n.keepAwakeOff }
        guard let until else { return L10n.keepAwakeIndefinite }
        return L10n.keepAwakeRemaining(max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up))))
    }

    private func refreshRows() {
        let symbol = isOn ? "cup.and.saucer.fill" : "cup.and.saucer"
        item.title = L10n.keepAwake
        item.subtitle = isOn ? detail : L10n.off
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        item.setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        guardRow.configure(symbol: symbol, title: L10n.keepAwake, detail: detail, isOn: isOn, isEnabled: true, help: L10n.keepAwakeToggle)
        for choice in durationItems {
            choice.state = (choice.representedObject as? NSNumber)?.intValue == minutes ? .on : .off
        }
        displayItem?.state = keepsDisplayOn ? .on : .off
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

    @objc private func chooseDuration(_ sender: NSMenuItem) {
        guard let minutes = (sender.representedObject as? NSNumber)?.intValue else { return }
        defaults.set(minutes, forKey: Self.minutesKey)
        turnOn()
    }

    /// Flips whether the display is held on too; a running hold is restarted with the new choice.
    @objc func toggleDisplay() {
        defaults.set(!keepsDisplayOn, forKey: Self.displayKey)
        if isOn, !service.start(keepDisplayOn: keepsDisplayOn) { turnOff() }
        refreshRows()
    }

    func toggle() { if isOn { turnOff() } else { turnOn() } }

    /// Starts (or restarts) the hold for the chosen duration. If macOS refuses, Battery settings opens instead.
    func turnOn() {
        guard service.start(keepDisplayOn: keepsDisplayOn) else {
            turnOff()
            closeMenus()
            onOpenSettings?(.battery)
            return
        }
        isOn = true
        expiry?.invalidate()
        if minutes > 0 {
            let end = Date().addingTimeInterval(TimeInterval(minutes) * 60)
            until = end
            let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.expire() }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiry = timer
        } else {
            until = nil
        }
        refreshRows()
    }

    func turnOff() {
        service.stop()
        isOn = false
        until = nil
        expiry?.invalidate()
        expiry = nil
        refreshRows()
    }

    /// A timed hold ran out.
    func expire() {
        guard isOn else { return }
        turnOff()
    }

    /// Releases the hold when the app quits.
    func stop() {
        if isOn { turnOff() }
        ticker?.invalidate()
    }
}
