import AppKit

enum SystemSettings {
    enum Page: String, CaseIterable {
        case wifi, network, battery, vpn, bluetooth, sound, focus, menubar

        var title: String {
            switch self {
            case .wifi: return "Wi-Fi 設定"
            case .network: return "網路設定"
            case .battery: return "電池設定"
            case .vpn: return "VPN 設定"
            case .bluetooth: return "藍牙設定"
            case .sound: return "聲音設定"
            case .focus: return "專注模式設定"
            case .menubar: return "選單列設定"
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
