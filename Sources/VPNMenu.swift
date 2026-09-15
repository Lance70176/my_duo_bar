import AppKit

/// The VPN item in the status menu and its submenu: one switch per VPN registered with macOS.
@MainActor
final class VPNMenuController: NSObject, NSMenuDelegate {
    static let rowWidth: CGFloat = 290

    let item = NSMenuItem()
    let submenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Called when a connection settles so the status monitor re-reads VPN state.
    var onVPNChanged: (() -> Void)?
    /// Runs the SystemConfiguration calls. Replaceable in tests so nothing real is switched.
    var service: VPNServing = SystemVPNService()

    private let worker = DispatchQueue(label: "com.rex.myduobar.vpn", qos: .userInitiated)
    private var status = SystemStatus()
    private(set) var configurations: [VPNConfiguration]?
    private var rows: [String: VPNRowView] = [:]
    private var switching: Set<String> = []
    private var submenuOpen = false

    override init() {
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        item.submenu = submenu
        update(status: status)
    }

    func update(status: SystemStatus) {
        let otherChanged = status.vpn.routedTunnel != self.status.vpn.routedTunnel || status.vpn.systemProxy != self.status.vpn.systemProxy
        self.status = status
        item.title = "VPN"
        item.subtitle = status.vpn.title
        item.image = NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        item.setAccessibilityLabel("VPN, " + status.vpn.title)
        if submenuOpen, otherChanged { rebuild() }
    }

    /// Called when the status menu opens, so the list is ready before the submenu appears.
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
            let list = service.list()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(list) } }
        }
    }

    /// Takes a fresh list. Rows are updated in place unless VPNs were added, removed or renamed.
    func apply(_ list: [VPNConfiguration]) {
        // A switch in progress owns its row until it settles; don't let an older read flip it back.
        let merged = list.map { config -> VPNConfiguration in
            guard switching.contains(config.id), let local = configurations?.first(where: { $0.id == config.id }) else { return config }
            return local
        }
        let sameShape = configurations?.map { [$0.id, $0.name] } == merged.map { [$0.id, $0.name] }
        configurations = merged
        guard submenuOpen else { return }
        if sameShape { merged.forEach { rows[$0.id]?.update($0) } } else { rebuild() }
    }

    func rebuild() {
        submenu.removeAllItems()
        rows.removeAll()
        submenu.addItem(NSMenuItem.sectionHeader(title: "VPN"))
        if let configurations {
            if configurations.isEmpty { submenu.addItem(note(L10n.noVPNConfigurations)) }
            for config in configurations {
                let row = VPNRowView(configuration: config) { [weak self] in self?.toggle(id: config.id) }
                rows[config.id] = row
                let menuItem = NSMenuItem(title: config.name, action: nil, keyEquivalent: "")
                menuItem.view = row
                submenu.addItem(menuItem)
            }
        } else {
            submenu.addItem(note(L10n.reading))
        }
        // VPNs macOS doesn't manage (Mihomo TUN, CLI OpenVPN) and proxies can only be reported.
        let managedOn = configurations?.contains { $0.status.isOn } ?? false
        if !managedOn, status.vpn.routedTunnel { submenu.addItem(note(L10n.vpnOtherRouteActive)) }
        if status.vpn.systemProxy { submenu.addItem(note(L10n.vpnSystemProxyActive)) }
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.vpnSettingsMenu, action: #selector(openVPNSettings), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)
    }

    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func closeMenus() {
        var root: NSMenu? = submenu
        while let parent = root?.supermenu { root = parent }
        root?.cancelTracking()
    }

    @objc private func openVPNSettings() {
        closeMenus()
        onOpenSettings?(.vpn)
    }

    private func setLocal(_ id: String, _ newStatus: VPNConnectionStatus) {
        guard let index = configurations?.firstIndex(where: { $0.id == id }) else { return }
        configurations?[index].status = newStatus
        if let config = configurations?[index] { rows[id]?.update(config) }
    }

    /// Connects or disconnects, keeps the menu open, and follows the status until it settles.
    func toggle(id: String) {
        guard !switching.contains(id), let config = configurations?.first(where: { $0.id == id }) else { return }
        let connect = !config.status.isOn
        switching.insert(id)
        setLocal(id, connect ? .connecting : .disconnecting)
        let service = self.service
        worker.async { [weak self] in
            let accepted = connect ? service.start(id: id) : service.stop(id: id)
            guard accepted else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.switching.remove(id)
                        self.setLocal(id, service.status(id: id))
                        self.closeMenus()
                        self.onOpenSettings?(.vpn)
                    }
                }
                return
            }
            // Poll for up to 30 s. Right after a start the service can still read "disconnected" briefly.
            var latest = VPNConnectionStatus.invalid
            for attempt in 0..<60 {
                Thread.sleep(forTimeInterval: service.pollInterval)
                latest = service.status(id: id)
                let snapshot = latest
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setLocal(id, snapshot) } }
                if connect {
                    if latest == .connected || ((latest == .disconnected || latest == .invalid) && attempt >= 4) { break }
                } else if latest == .disconnected || latest == .invalid {
                    break
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.switching.remove(id)
                    self.onVPNChanged?()
                    self.reload()
                }
            }
        }
    }
}

/// The VPN calls the menu needs; `SystemVPNService` is the real one.
protocol VPNServing: Sendable {
    var pollInterval: TimeInterval { get }
    func list() -> [VPNConfiguration]
    func status(id: String) -> VPNConnectionStatus
    func start(id: String) -> Bool
    func stop(id: String) -> Bool
}

struct SystemVPNService: VPNServing {
    var pollInterval: TimeInterval { 0.5 }
    func list() -> [VPNConfiguration] { VPNService.list() }
    func status(id: String) -> VPNConnectionStatus { VPNService.status(id: id) }
    func start(id: String) -> Bool { VPNService.start(id: id) }
    func stop(id: String) -> Bool { VPNService.stop(id: id) }
}

/// One VPN: key badge (accent when on), name, status line and a switch. The whole row toggles.
final class VPNRowView: NSView {
    private(set) var configuration: VPNConfiguration
    let toggleSwitch: MenuSwitch
    private let onToggle: () -> Void
    private let badge = NSView()
    private let glyph = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    override var allowsVibrancy: Bool { true }

    init(configuration: VPNConfiguration, onToggle: @escaping () -> Void) {
        self.configuration = configuration
        self.onToggle = onToggle
        toggleSwitch = MenuSwitch(isOn: configuration.status.isOn)
        super.init(frame: NSRect(x: 0, y: 0, width: VPNMenuController.rowWidth, height: 42))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 12
        glyph.image = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for view in [badge, name, detail, toggleSwitch] as [NSView] {
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
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            name.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -10),
            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        update(configuration)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ configuration: VPNConfiguration) {
        self.configuration = configuration
        name.stringValue = configuration.name
        detail.stringValue = configuration.status.title
        toggleSwitch.isOn = configuration.status.isOn
        toggleSwitch.isEnabled = !configuration.status.isTransitioning && configuration.status != .invalid
        applyColors()
        setAccessibilityLabel(configuration.name + ", " + configuration.status.title)
        setAccessibilityValue(configuration.status.isOn)
        setAccessibilityHelp(L10n.vpnToggle(configuration.name))
    }

    private func applyColors() {
        let on = configuration.status.isOn
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).cgColor
        }
        glyph.contentTintColor = on ? .white : .labelColor
    }
    override func viewDidChangeEffectiveAppearance() { applyColors() }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {
        if enclosingMenuItem?.isHighlighted == true {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), toggleSwitch.isEnabled else { return }
        onToggle()
    }
    override func accessibilityPerformPress() -> Bool {
        guard toggleSwitch.isEnabled else { return false }
        onToggle(); return true
    }
}
