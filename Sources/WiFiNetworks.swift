import Foundation

/// One network shown in the Wi-Fi submenu.
struct WiFiNetwork: Equatable, Hashable, Sendable {
    var ssid: String
    var rssi: Int
    var secure: Bool
    var known: Bool
    var current: Bool
    var channel: Int?

    /// Same thresholds as the menu bar icon: 3 strong, 2 fair, 1 weak.
    var signalLevel: Int { rssi >= -60 ? 3 : (rssi >= -72 ? 2 : 1) }
    var signalQuality: String {
        switch signalLevel {
        case 3: return L10n.signalStrong
        case 2: return L10n.signalFair
        default: return L10n.signalWeak
        }
    }
}

/// Snapshot of a scan, grouped the way the system Wi-Fi menu groups networks.
struct WiFiScanResult: Equatable, Sendable {
    var powered = false
    /// The scan found networks but macOS withheld every name (no Location permission).
    var namesHidden = false
    /// Saved networks currently in range; the connected one first, then strongest first.
    var known: [WiFiNetwork] = []
    /// Unsaved networks in range, strongest first.
    var other: [WiFiNetwork] = []
}

enum WiFiNetworkList {
    /// A raw scan entry, before grouping. `ssid` is nil when macOS hides it.
    struct Raw: Equatable, Sendable {
        var ssid: String?
        var rssi: Int
        var secure: Bool
        var channel: Int?
    }

    /// Groups raw scan entries.
    /// - Parameters:
    ///   - currentSSID: the associated network's name, when macOS reveals it.
    ///   - currentChannel/currentRSSI: used to recognise the associated network when its name is hidden
    ///     but scan results still carry names. Pass nil when not associated.
    static func build(raw: [Raw], knownSSIDs: Set<String>, powered: Bool,
                      currentSSID: String?, currentChannel: Int?, currentRSSI: Int?) -> WiFiScanResult {
        var result = WiFiScanResult(powered: powered)
        guard powered else { return result }
        let named = raw.filter { !($0.ssid ?? "").isEmpty }
        result.namesHidden = !raw.isEmpty && named.isEmpty

        // Several access points can share one name (mesh, 2.4/5 GHz): keep the strongest.
        var strongest: [String: Raw] = [:]
        for entry in named {
            let ssid = entry.ssid!
            if let existing = strongest[ssid] {
                var merged = entry.rssi > existing.rssi ? entry : existing
                merged.secure = existing.secure || entry.secure
                strongest[ssid] = merged
            } else {
                strongest[ssid] = entry
            }
        }

        var current = currentSSID.flatMap { strongest[$0] != nil ? $0 : nil }
        if current == nil, currentSSID == nil, let channel = currentChannel {
            let candidates = strongest.values.filter { knownSSIDs.contains($0.ssid!) && $0.channel == channel }
            if candidates.count == 1 {
                current = candidates[0].ssid
            } else if let rssi = currentRSSI {
                current = candidates.min { abs($0.rssi - rssi) < abs($1.rssi - rssi) }?.ssid
            }
        }

        let networks = strongest.values.map { entry in
            WiFiNetwork(ssid: entry.ssid!, rssi: entry.rssi, secure: entry.secure,
                        known: knownSSIDs.contains(entry.ssid!) || entry.ssid == current,
                        current: entry.ssid == current, channel: entry.channel)
        }
        let byStrength: (WiFiNetwork, WiFiNetwork) -> Bool = {
            $0.rssi != $1.rssi ? $0.rssi > $1.rssi : $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending
        }
        result.known = networks.filter(\.known).sorted { lhs, rhs in
            lhs.current != rhs.current ? lhs.current : byStrength(lhs, rhs)
        }
        result.other = networks.filter { !$0.known }.sorted(by: byStrength)
        return result
    }
}
