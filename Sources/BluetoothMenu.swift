import AppKit

/// The Bluetooth item in the status menu and its submenu: one switch per paired device.
/// Choosing a device connects or disconnects it, like the system Bluetooth menu.
@MainActor
final class BluetoothMenuController: NSObject, NSMenuDelegate {
    static let rowWidth: CGFloat = 290
    /// While the submenu is open, devices are re-read this often so connections made elsewhere show up.
    static let refreshInterval: TimeInterval = 2

    let item = NSMenuItem()
    let submenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Called when a connection settles so the status monitor re-reads audio (headphones come and go).
    var onBluetoothChanged: (() -> Void)?
    /// Runs the IOBluetooth calls. Replaceable in tests so nothing real is connected.
    var service: BluetoothServing = SystemBluetoothService()

    private let worker = DispatchQueue(label: "com.rex.myduobar.bluetooth", qos: .userInitiated)
    private(set) var state: BluetoothState?
    private var rows: [String: BluetoothRowView] = [:]
    private var switching: Set<String> = []
    private var submenuOpen = false
    private var refreshTimer: Timer?

    override init() {
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        item.submenu = submenu
        item.title = L10n.bluetooth
        item.image = NSImage(named: "NSBluetoothTemplate")
        refreshItem()
    }

    /// The status monitor doesn't read Bluetooth; the item follows this controller's own reads.
    func update(status: SystemStatus) { refreshItem() }

    private func refreshItem() {
        item.title = L10n.bluetooth
        item.subtitle = state?.title ?? L10n.reading
        item.setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    /// Called when the status menu opens, so the list is ready before the submenu appears.
    func prepare() { reload() }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        submenuOpen = true
        rebuild()
        reload()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(refreshTimer!, forMode: .eventTracking)
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === submenu else { return }
        submenuOpen = false
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func reload() {
        let service = self.service
        worker.async { [weak self] in
            let fresh = service.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(fresh) } }
        }
    }

    /// Takes a fresh read. Rows are updated in place unless devices were added, removed or renamed.
    func apply(_ fresh: BluetoothState) {
        var merged = fresh
        // A switch in progress owns its row until it settles; don't let an older read flip it back.
        merged.devices = fresh.devices.map { device in
            guard switching.contains(device.id), let local = state?.devices.first(where: { $0.id == device.id }) else { return device }
            return local
        }
        let sameShape = state?.powered == merged.powered && state?.devices.map { [$0.id, $0.name] } == merged.devices.map { [$0.id, $0.name] }
        state = merged
        refreshItem()
        guard submenuOpen else { return }
        if sameShape { merged.devices.forEach { rows[$0.id]?.update($0) } } else { rebuild() }
    }

    func rebuild() {
        refreshItem()
        submenu.removeAllItems()
        rows.removeAll()
        if let state, state.powered == true {
            submenu.addItem(NSMenuItem.sectionHeader(title: L10n.bluetoothDevices))
            if state.devices.isEmpty { submenu.addItem(note(L10n.noPairedDevices)) }
            for device in state.devices {
                let row = BluetoothRowView(device: device) { [weak self] in self?.toggle(id: device.id) }
                rows[device.id] = row
                let menuItem = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
                menuItem.view = row
                submenu.addItem(menuItem)
            }
        } else {
            submenu.addItem(NSMenuItem.sectionHeader(title: L10n.bluetooth))
            if let state { submenu.addItem(note(state.powered == nil ? L10n.bluetoothUnavailable : L10n.bluetoothOff)) }
            else { submenu.addItem(note(L10n.reading)) }
        }
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.bluetoothSettingsMenu, action: #selector(openBluetoothSettings), keyEquivalent: "")
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

    @objc private func openBluetoothSettings() {
        closeMenus()
        onOpenSettings?(.bluetooth)
    }

    private func setLocal(_ id: String, _ status: BluetoothDevice.Status) {
        guard let index = state?.devices.firstIndex(where: { $0.id == id }) else { return }
        state?.devices[index].status = status
        if let device = state?.devices[index] { rows[id]?.update(device) }
        refreshItem()
    }

    /// Connects or disconnects, keeps the menu open, and follows the device until it settles.
    /// If macOS refuses, Bluetooth settings opens instead.
    func toggle(id: String) {
        guard !switching.contains(id), let device = state?.devices.first(where: { $0.id == id }) else { return }
        let connect = !device.status.isOn
        switching.insert(id)
        setLocal(id, connect ? .connecting : .disconnecting)
        let service = self.service
        worker.async { [weak self] in
            let accepted = connect ? service.connect(id: id) : service.disconnect(id: id)
            guard accepted else {
                let fresh = service.read()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.switching.remove(id)
                        self.apply(fresh)
                        self.closeMenus()
                        self.onOpenSettings?(.bluetooth)
                    }
                }
                return
            }
            // A connection is usually up when the call returns; give the profiles a moment to follow.
            var latest = service.read()
            for _ in 0..<20 {
                let status = latest.devices.first { $0.id == id }?.status
                if status == (connect ? .connected : .disconnected) || status == nil { break }
                Thread.sleep(forTimeInterval: service.pollInterval)
                latest = service.read()
            }
            let settled = latest
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.switching.remove(id)
                    self.apply(settled)
                    self.onBluetoothChanged?()
                }
            }
        }
    }
}

/// The IOBluetooth calls the menu needs; `SystemBluetoothService` is the real one.
protocol BluetoothServing: Sendable {
    var pollInterval: TimeInterval { get }
    func read() -> BluetoothState
    func connect(id: String) -> Bool
    func disconnect(id: String) -> Bool
}

struct SystemBluetoothService: BluetoothServing {
    var pollInterval: TimeInterval { 0.5 }
    func read() -> BluetoothState { BluetoothService.read() }
    func connect(id: String) -> Bool { BluetoothService.connect(id: id) }
    func disconnect(id: String) -> Bool { BluetoothService.disconnect(id: id) }
}

/// One paired device: badge (accent when connected), name, status line and a switch. The whole row toggles.
final class BluetoothRowView: SwitchRowView {
    private(set) var device: BluetoothDevice

    init(device: BluetoothDevice, onToggle: @escaping () -> Void) {
        self.device = device
        super.init(width: BluetoothMenuController.rowWidth)
        self.onToggle = onToggle
        update(device)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ device: BluetoothDevice) {
        self.device = device
        configure(symbol: device.symbol, title: device.name, detail: device.status.title,
                  isOn: device.status.isOn, isEnabled: !device.status.isTransitioning,
                  help: L10n.bluetoothToggle(device.name))
    }
}
