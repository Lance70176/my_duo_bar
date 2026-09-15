import CoreWLAN
import Foundation

/// Blocking CoreWLAN calls. Call only from a background queue; every result is a value type.
enum WiFiService {
    static func scan() -> WiFiScanResult {
        guard let interface = CWWiFiClient.shared().interface() else { return WiFiScanResult() }
        let powered = interface.powerOn()
        guard powered else { return WiFiScanResult(powered: false) }
        let found = (try? interface.scanForNetworks(withName: nil)) ?? []
        let raw = found.map { network in
            WiFiNetworkList.Raw(ssid: network.ssid, rssi: network.rssiValue,
                                secure: !network.supportsSecurity(.none),
                                channel: network.wlanChannel.map { Int($0.channelNumber) })
        }
        let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        let associated = interface.interfaceMode() == .station
        return WiFiNetworkList.build(
            raw: raw, knownSSIDs: Set(profiles.compactMap(\.ssid)), powered: true,
            currentSSID: interface.ssid(),
            currentChannel: associated ? interface.wlanChannel().map { Int($0.channelNumber) } : nil,
            currentRSSI: associated ? interface.rssiValue() : nil)
    }

    /// Returns false when macOS refuses the change (for example, a managed Mac).
    static func setPower(_ on: Bool) -> Bool {
        guard let interface = CWWiFiClient.shared().interface() else { return false }
        do { try interface.setPower(on); return true } catch { return false }
    }

    enum JoinOutcome: Sendable, Equatable { case joined, needsSystemSettings }

    /// Joins an open network directly. A secured network is joined only with a password already in the
    /// keychain; macOS may ask the user to authorize reading it. Anything else is left to System Settings.
    static func join(ssid: String) -> JoinOutcome {
        guard let interface = CWWiFiClient.shared().interface(),
              let candidates = try? interface.scanForNetworks(withName: ssid),
              let network = candidates.max(by: { $0.rssiValue < $1.rssiValue }) else { return .needsSystemSettings }
        if network.supportsSecurity(.none) {
            return (try? interface.associate(to: network, password: nil)) != nil ? .joined : .needsSystemSettings
        }
        guard let data = ssid.data(using: .utf8) else { return .needsSystemSettings }
        for domain in [CWKeychainDomain.user, .system] {
            var password: NSString?
            guard CWKeychainFindWiFiPassword(domain, data, &password) == errSecSuccess, let password else { continue }
            if (try? interface.associate(to: network, password: password as String)) != nil { return .joined }
        }
        return .needsSystemSettings
    }
}
