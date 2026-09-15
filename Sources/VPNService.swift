import Foundation
import SystemConfiguration

enum VPNConnectionStatus: Equatable, Sendable {
    case disconnected, connecting, connected, disconnecting, invalid

    init(_ status: SCNetworkConnectionStatus) {
        switch status {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .disconnecting: self = .disconnecting
        case .disconnected: self = .disconnected
        default: self = .invalid
        }
    }

    /// Whether the switch shows "on": a connection that is up or on its way up.
    var isOn: Bool { self == .connected || self == .connecting }
    var isTransitioning: Bool { self == .connecting || self == .disconnecting }

    var title: String {
        switch self {
        case .connected: return L10n.connected
        case .connecting: return L10n.vpnConnecting
        case .disconnecting: return L10n.vpnDisconnecting
        case .disconnected: return L10n.notConnected
        case .invalid: return L10n.vpnInvalid
        }
    }
}

/// A VPN registered with macOS (System Settings → VPN), including app-provided ones such as Tailscale.
struct VPNConfiguration: Equatable, Sendable {
    var id: String
    var name: String
    var status: VPNConnectionStatus
}

/// SystemConfiguration calls, the same public API `scutil --nc` uses. Safe to call from a background queue.
enum VPNService {
    static func list() -> [VPNConfiguration] {
        guard let prefs = SCPreferencesCreate(nil, "MyDuoBar" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [] }
        return services.compactMap { service -> VPNConfiguration? in
            guard SCNetworkServiceGetEnabled(service),
                  let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  ["VPN", "IPSec", "PPP"].contains(type),
                  let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            let name = (SCNetworkServiceGetName(service) as String?) ?? "VPN"
            return VPNConfiguration(id: id, name: name, status: status(id: id))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func status(id: String) -> VPNConnectionStatus {
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil) else { return .invalid }
        return VPNConnectionStatus(SCNetworkConnectionGetStatus(connection))
    }

    /// Asks macOS to connect. Returns false when the request was refused outright.
    static func start(id: String) -> Bool {
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil) else { return false }
        // nil options = the service's own configured settings, as `scutil --nc start <service>` does.
        // Don't use SCNetworkConnectionCopyUserPreferences here: it returns the *default* service's options.
        // linger: keep the VPN up after this app releases the connection or quits.
        return SCNetworkConnectionStart(connection, nil, true)
    }

    static func stop(id: String) -> Bool {
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil) else { return false }
        return SCNetworkConnectionStop(connection, true)
    }
}
