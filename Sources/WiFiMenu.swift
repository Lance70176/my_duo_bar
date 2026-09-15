import AppKit
import CoreLocation

/// The Wi-Fi item in the status menu and the submenu it opens to the right, modelled on the system Wi-Fi menu.
@MainActor
final class WiFiMenuController: NSObject, NSMenuDelegate, CLLocationManagerDelegate {
    static let rowWidth: CGFloat = 290
    /// Scans older than this are refreshed when a menu opens.
    static let staleAfter: TimeInterval = 15

    let item = NSMenuItem()
    let submenu = NSMenu()
    private let otherMenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Called after a power change or a join so the status monitor re-reads Wi-Fi.
    var onWiFiChanged: (() -> Void)?

    private let worker = DispatchQueue(label: "com.rex.myduobar.wifi", qos: .userInitiated)
    private let location = CLLocationManager()
    private var status = SystemStatus()
    private(set) var result: WiFiScanResult?
    private var lastScan: Date?
    private(set) var scanning = false
    private var submenuOpen = false

    override init() {
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        otherMenu.autoenablesItems = false
        location.delegate = self
        update(status: status)
    }

    // MARK: Parent item

    func update(status: SystemStatus) {
        let powerChanged = status.wifi.powered != self.status.wifi.powered
        self.status = status
        let wifi = status.wifi
        item.image = NSImage(systemSymbolName: wifi.associated || wifi.route != .ethernet ? wifi.symbol : "wifi",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        if wifi.available {
            item.title = "Wi-Fi"
            if wifi.associated { item.subtitle = wifi.title + " · " + wifi.signalQuality }
            else if wifi.route == .ethernet { item.subtitle = (wifi.powered ? L10n.notConnected : L10n.turnedOff) + " · " + L10n.ethernetConnected }
            else { item.subtitle = wifi.powered ? L10n.notConnected : L10n.turnedOff }
            item.submenu = submenu
            item.action = nil
        } else {
            // No Wi-Fi hardware: behave like the old row and open network settings.
            item.title = wifi.route == .ethernet ? L10n.ethernet : "Wi-Fi"
            item.subtitle = wifi.title
            item.submenu = nil
            item.target = self
            item.action = #selector(openNetworkSettings)
        }
        item.setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        // The submenu only depends on the power state; status refreshes every few seconds while open.
        if submenuOpen, powerChanged { rebuild() }
    }

    /// Called when the status menu opens, so results are usually ready before the submenu is shown.
    func prepare() {
        guard status.wifi.available else { return }
        scanIfStale()
    }

    @objc private func openNetworkSettings() { onOpenSettings?(.network) }

    // MARK: Scanning

    private func scanIfStale() {
        if let lastScan, Date().timeIntervalSince(lastScan) < Self.staleAfter { return }
        scan()
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        // Only placeholders mention scanning; avoid rebuilding (and closing nested menus) otherwise.
        if submenuOpen, result == nil { rebuild() }
        worker.async { [weak self] in
            let snapshot = WiFiService.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishScan(snapshot) }
            }
        }
    }

    func finishScan(_ snapshot: WiFiScanResult) {
        scanning = false
        let changed = snapshot != result
        result = snapshot
        lastScan = Date()
        if submenuOpen, changed || snapshot.known.isEmpty || snapshot.other.isEmpty { rebuild() }
    }

    // MARK: Submenu

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        submenuOpen = true
        rebuild()
        scanIfStale()
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === submenu { submenuOpen = false }
    }

    /// Rebuilds the submenu from the latest status and scan. Safe while the menu is open.
    func rebuild() {
        submenu.removeAllItems()
        let powered = status.wifi.powered
        let toggle = NSMenuItem()
        toggle.view = WiFiToggleRowView(on: powered) { [weak self] on in self?.setPower(on) }
        submenu.addItem(toggle)

        if powered {
            if result?.namesHidden == true {
                submenu.addItem(.separator())
                let allow = NSMenuItem(title: L10n.allowNetworkNames, action: #selector(requestLocation), keyEquivalent: "")
                allow.target = self
                submenu.addItem(allow)
            } else {
                submenu.addItem(NSMenuItem.sectionHeader(title: L10n.knownNetworks))
                let known = result?.known ?? []
                if known.isEmpty {
                    submenu.addItem(placeholder(result == nil || scanning ? L10n.scanningNetworks : L10n.noKnownNetworksNearby))
                } else {
                    known.forEach { submenu.addItem(networkItem($0)) }
                }
                otherMenu.removeAllItems()
                let other = result?.other ?? []
                if other.isEmpty {
                    otherMenu.addItem(placeholder(result == nil || scanning ? L10n.scanningNetworks : L10n.noNetworksFound))
                } else {
                    other.forEach { otherMenu.addItem(networkItem($0)) }
                }
                let otherItem = NSMenuItem(title: L10n.otherNetworks, action: nil, keyEquivalent: "")
                otherItem.submenu = otherMenu
                submenu.addItem(.separator())
                submenu.addItem(otherItem)
            }
        }
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.wifiSettingsMenu, action: #selector(openWiFiSettings), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)
    }

    private func placeholder(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func networkItem(_ network: WiFiNetwork) -> NSMenuItem {
        let item = NSMenuItem(title: network.ssid, action: #selector(selectNetwork(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = network.ssid
        item.view = WiFiNetworkRowView(network: network) { [weak self, weak item] in
            guard let item else { return }
            self?.selectNetwork(item)
        }
        return item
    }

    // MARK: Actions

    private func closeMenus() {
        var root: NSMenu? = submenu
        while let parent = root?.supermenu { root = parent }
        root?.cancelTracking()
    }

    @objc private func openWiFiSettings() {
        closeMenus()
        onOpenSettings?(.wifi)
    }

    @objc private func requestLocation() {
        closeMenus()
        location.requestWhenInUseAuthorization()
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.lastScan = nil
            self?.onWiFiChanged?()
        }
    }

    private func setPower(_ on: Bool) {
        worker.async { [weak self] in
            let succeeded = WiFiService.setPower(on)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if succeeded {
                        self.status.wifi.powered = on
                        self.lastScan = nil
                        if !on { self.result = WiFiScanResult(powered: false) }
                        if self.submenuOpen { self.rebuild() }
                        self.onWiFiChanged?()
                        if on { self.scan() }
                    } else {
                        // macOS refused (managed Mac, missing rights): put the switch back and hand over.
                        if self.submenuOpen { self.rebuild() }
                        self.closeMenus()
                        self.onOpenSettings?(.wifi)
                    }
                }
            }
        }
    }

    @objc private func selectNetwork(_ sender: NSMenuItem) {
        guard let ssid = sender.representedObject as? String else { return }
        closeMenus()
        let all = (result?.known ?? []) + (result?.other ?? [])
        if all.first(where: { $0.ssid == ssid })?.current == true { return }
        worker.async { [weak self] in
            let outcome = WiFiService.join(ssid: ssid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastScan = nil
                    switch outcome {
                    case .joined: self.onWiFiChanged?()
                    case .needsSystemSettings: self.onOpenSettings?(.wifi)
                    }
                }
            }
        }
    }
}

// MARK: - Views

/// "Wi-Fi" title with a switch, like the top row of the system menu.
final class WiFiToggleRowView: NSView {
    let toggle = NSSwitch()
    private let onToggle: (Bool) -> Void

    init(on: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: WiFiMenuController.rowWidth, height: 34))
        let label = NSTextField(labelWithString: "Wi-Fi")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        toggle.state = on ? .on : .off
        toggle.controlSize = .small
        toggle.target = self; toggle.action = #selector(changed)
        toggle.setAccessibilityLabel(L10n.wifiPower)
        for view in [label, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { onToggle(toggle.state == .on) }
}

/// A network row: round signal badge (blue when connected), name, and a lock for secured networks.
final class WiFiNetworkRowView: NSView {
    let network: WiFiNetwork
    private let onSelect: () -> Void
    private let badge = NSView()
    private let glyph = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let lock = NSImageView()
    override var allowsVibrancy: Bool { true }

    init(network: WiFiNetwork, onSelect: @escaping () -> Void) {
        self.network = network
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: WiFiMenuController.rowWidth, height: 32))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 12
        glyph.image = NSImage(systemSymbolName: "wifi", variableValue: Double(network.signalLevel) / 3, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        name.stringValue = network.ssid
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        lock.contentTintColor = .secondaryLabelColor
        lock.isHidden = !network.secure
        for view in [badge, name, lock] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        glyph.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(glyph)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            glyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 9),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: lock.leadingAnchor, constant: -8),
            lock.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            lock.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        let parts = [network.ssid, network.signalQuality, network.secure ? L10n.secured : nil, network.current ? L10n.connected : nil]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(parts.compactMap { $0 }.joined(separator: ", "))
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var highlighted: Bool { enclosingMenuItem?.isHighlighted == true }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = (network.current ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).cgColor
        }
        glyph.contentTintColor = network.current ? .white : .labelColor
    }
    override func viewDidChangeEffectiveAppearance() { applyColors() }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect()
    }
}
