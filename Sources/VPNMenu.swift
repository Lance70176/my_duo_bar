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
final class VPNRowView: SwitchRowView {
    private(set) var configuration: VPNConfiguration

    init(configuration: VPNConfiguration, onToggle: @escaping () -> Void) {
        self.configuration = configuration
        super.init(width: VPNMenuController.rowWidth)
        self.onToggle = onToggle
        update(configuration)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ configuration: VPNConfiguration) {
        self.configuration = configuration
        configure(symbol: "key.horizontal.fill", title: configuration.name, detail: configuration.status.title,
                  isOn: configuration.status.isOn,
                  isEnabled: !configuration.status.isTransitioning && configuration.status != .invalid,
                  help: L10n.vpnToggle(configuration.name))
    }
}
