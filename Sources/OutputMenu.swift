import AppKit

/// The Headphones item in the status menu and its submenu: every output device, with the current one checked.
/// Choosing a device makes it the default output, like the system Sound menu.
@MainActor
final class OutputMenuController: NSObject, NSMenuDelegate {
    let item = NSMenuItem()
    let submenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Called after switching so the status monitor re-reads audio.
    var onOutputChanged: (() -> Void)?
    /// Runs the Core Audio calls. Replaceable in tests so the real output is never changed.
    var service: OutputDeviceServing = SystemOutputDeviceService()

    private let worker = DispatchQueue(label: "com.rex.myduobar.output", qos: .userInitiated)
    private(set) var devices: [AudioOutputDevice]?
    private var submenuOpen = false

    override init() {
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        item.submenu = submenu
        update(status: SystemStatus())
    }

    func update(status: SystemStatus) {
        let audio = status.audio
        item.title = L10n.headphones
        item.subtitle = audio.headphoneTitle
        item.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        item.setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        // Devices come and go (AirPods connecting); follow them while the submenu is visible.
        if submenuOpen { reload() }
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
            let list = service.outputDevices()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(list) } }
        }
    }

    func apply(_ list: [AudioOutputDevice]) {
        guard list != devices else { return }
        devices = list
        if submenuOpen { rebuild() }
    }

    func rebuild() {
        submenu.removeAllItems()
        submenu.addItem(NSMenuItem.sectionHeader(title: L10n.outputDevices))
        if let devices {
            if devices.isEmpty { submenu.addItem(note(L10n.noOutputDevices)) }
            for device in devices {
                let row = NSMenuItem(title: device.name, action: #selector(chooseDevice(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = NSNumber(value: device.id)
                row.state = device.isDefault ? .on : .off
                row.image = (NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil)
                             ?? NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil))?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
                submenu.addItem(row)
            }
        } else {
            submenu.addItem(note(L10n.reading))
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

    @objc private func openBluetoothSettings() { onOpenSettings?(.bluetooth) }

    @objc private func chooseDevice(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        select(id: id)
    }

    /// Switches the default output. If macOS refuses, Sound settings opens instead.
    func select(id: UInt32) {
        guard let index = devices?.firstIndex(where: { $0.id == id }), devices?[index].isDefault == false else { return }
        let service = self.service
        worker.async { [weak self] in
            let switched = service.selectOutput(id: id)
            let list = service.outputDevices()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(list)
                    if switched { self.onOutputChanged?() } else { self.onOpenSettings?(.sound) }
                }
            }
        }
    }
}

/// The Core Audio calls the Headphones submenu needs; `SystemOutputDeviceService` is the real one.
protocol OutputDeviceServing: Sendable {
    func outputDevices() -> [AudioOutputDevice]
    func selectOutput(id: UInt32) -> Bool
}

struct SystemOutputDeviceService: OutputDeviceServing {
    func outputDevices() -> [AudioOutputDevice] { SoundService.outputDevices() }
    func selectOutput(id: UInt32) -> Bool { SoundService.selectOutput(id: id) }
}
