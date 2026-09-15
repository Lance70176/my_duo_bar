import AppKit

enum SystemSettings {
    enum Page: String, CaseIterable {
        case wifi, network, battery, vpn, bluetooth, sound, focus, menubar

        var title: String {
            switch self {
            case .wifi: return L10n.wifiSettings
            case .network: return L10n.networkSettings
            case .battery: return L10n.batterySettings
            case .vpn: return L10n.vpnSettings
            case .bluetooth: return L10n.bluetoothSettings
            case .sound: return L10n.soundSettings
            case .focus: return L10n.focusSettings
            case .menubar: return L10n.menuBarSettings
            }
        }

        var url: URL {
            let target: String
            switch self {
            case .wifi: target = "com.apple.wifi-settings-extension"
            case .network: target = "com.apple.Network-Settings.extension"
            case .battery: target = "com.apple.Battery-Settings.extension"
            case .vpn: target = "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"
            case .bluetooth: target = "com.apple.BluetoothSettings"
            case .sound: target = "com.apple.Sound-Settings.extension"
            case .focus: target = "com.apple.Focus-Settings.extension"
            case .menubar: target = "com.apple.ControlCenter-Settings.extension"
            }
            return URL(string: "x-apple.systempreferences:" + target)!
        }
    }

    @discardableResult static func open(_ page: Page) -> Bool {
        NSWorkspace.shared.open(page.url)
    }
}
