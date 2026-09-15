import Foundation
import Synchronization
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

    /// `ne_session_status_t`: 1 disconnected, 2 connecting, 3 connected, 4 reasserting, 5 disconnecting.
    init(sessionStatus: Int32) {
        switch sessionStatus {
        case 1: self = .disconnected
        case 2, 4: self = .connecting
        case 3: self = .connected
        case 5: self = .disconnecting
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

/// Lists and switches VPNs. Network Extension sees every VPN in System Settings, including IKEv2 VPNs
/// installed by configuration profiles; SystemConfiguration is the fallback if that interface is unavailable.
/// Safe to call from a background queue.
enum VPNService {
    static func list() -> [VPNConfiguration] {
        let configurations = NetworkExtensionVPN.list() ?? SystemConfigurationVPN.list()
        return configurations.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func status(id: String) -> VPNConnectionStatus {
        NetworkExtensionVPN.status(id: id) ?? SystemConfigurationVPN.status(id: id)
    }

    /// Asks macOS to connect. Returns false when the request was refused outright.
    static func start(id: String) -> Bool {
        NetworkExtensionVPN.start(id: id) ?? SystemConfigurationVPN.start(id: id)
    }

    static func stop(id: String) -> Bool {
        NetworkExtensionVPN.stop(id: id) ?? SystemConfigurationVPN.stop(id: id)
    }
}

/// The interface the system VPN menu uses: `NEConfigurationManager` to list configurations and the
/// `ne_session` functions to read and change their state. Neither is public API, so every call is looked up
/// at run time and returns nil when missing, and the caller falls back to SystemConfiguration.
/// No VPN secrets are read: only each configuration's name and identifier.
enum NetworkExtensionVPN {
    private typealias LoadConfigurations = @convention(c) (AnyObject, Selector, DispatchQueue,
                                                         @escaping @convention(block) (NSArray?, NSError?) -> Void) -> Void
    private typealias SessionCreate = @convention(c) (UnsafePointer<UInt8>, Int32) -> OpaquePointer?
    private typealias SessionAction = @convention(c) (OpaquePointer) -> Void
    private typealias SessionGetStatus = @convention(c) (OpaquePointer, DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void

    private struct Functions: @unchecked Sendable {
        let create: SessionCreate
        let getStatus: SessionGetStatus
        let start: SessionAction
        let stop: SessionAction
    }
    private struct Session: @unchecked Sendable { let pointer: OpaquePointer }
    /// Carries a callback's result back to the waiting thread.
    private final class Reply<Value: Sendable>: Sendable {
        private let value = Mutex<Value?>(nil)
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
        func get() -> Value? { value.withLock { $0 } }
    }

    private static let functions: Functions? = {
        let process = dlopen(nil, RTLD_NOW)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(process, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("ne_session_create", as: SessionCreate.self),
              let getStatus = symbol("ne_session_get_status", as: SessionGetStatus.self),
              let start = symbol("ne_session_start", as: SessionAction.self),
              let stop = symbol("ne_session_stop", as: SessionAction.self) else { return nil }
        return Functions(create: create, getStatus: getStatus, start: start, stop: stop)
    }()
    /// Sessions stay open for the life of the app so a connection isn't tied to a released handle.
    private static let sessions = Mutex<[String: Session]>([:])
    private static let callbackQueue = DispatchQueue(label: "com.rex.myduobar.vpn.session")
    /// `NESessionType` for a VPN.
    private static let vpnSessionType: Int32 = 1

    private struct Identity: Sendable { let id: String; let name: String }

    static func list() -> [VPNConfiguration]? {
        // Nothing references the framework directly, so the linker doesn't load it; load it before the class lookup.
        guard functions != nil, Bundle(path: "/System/Library/Frameworks/NetworkExtension.framework")?.load() == true,
              let managerClass = NSClassFromString("NEConfigurationManager") as? NSObject.Type else { return nil }
        let sharedSelector = NSSelectorFromString("sharedManager")
        let loadSelector = NSSelectorFromString("loadConfigurationsWithCompletionQueue:handler:")
        guard managerClass.responds(to: sharedSelector),
              let manager = managerClass.perform(sharedSelector)?.takeUnretainedValue() as? NSObject,
              manager.responds(to: loadSelector) else { return nil }
        let load = unsafeBitCast(manager.method(for: loadSelector), to: LoadConfigurations.self)
        let loaded = Reply<[Identity]>()
        let done = DispatchSemaphore(value: 0)
        load(manager, loadSelector, callbackQueue) { configurations, error in
            if error == nil, let configurations {
                // Only entries with a VPN payload appear in System Settings → VPN; firewall and privacy entries don't.
                loaded.set(configurations.compactMap { item -> Identity? in
                    guard let object = item as? NSObject,
                          let vpn = property(object, "VPN"), !(vpn is NSNull),
                          let identifier = property(object, "identifier") as? NSUUID,
                          let name = property(object, "name") as? String else { return nil }
                    return Identity(id: identifier.uuidString, name: name)
                })
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success, let identities = loaded.get() else { return nil }
        return identities.map { VPNConfiguration(id: $0.id, name: $0.name, status: status(id: $0.id) ?? .invalid) }
    }

    static func status(id: String) -> VPNConnectionStatus? {
        guard let functions, let session = session(id: id) else { return nil }
        let result = Reply<Int32>()
        let done = DispatchSemaphore(value: 0)
        functions.getStatus(session.pointer, callbackQueue) { status in
            result.set(status)
            done.signal()
        }
        guard done.wait(timeout: .now() + 3) == .success, let status = result.get() else { return .invalid }
        return VPNConnectionStatus(sessionStatus: status)
    }

    static func start(id: String) -> Bool? {
        guard let functions, let session = session(id: id) else { return nil }
        functions.start(session.pointer)
        return true
    }

    static func stop(id: String) -> Bool? {
        guard let functions, let session = session(id: id) else { return nil }
        functions.stop(session.pointer)
        return true
    }

    private static func session(id: String) -> Session? {
        guard let functions, let uuid = UUID(uuidString: id) else { return nil }
        return sessions.withLock { cache in
            if let cached = cache[id] { return cached }
            let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            guard let pointer = bytes.withUnsafeBufferPointer({ functions.create($0.baseAddress!, vpnSessionType) }) else { return nil }
            let session = Session(pointer: pointer)
            cache[id] = session
            return session
        }
    }

    /// Key-value lookup that returns nil instead of raising when a private class lacks the property.
    private static func property(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }
}

/// SystemConfiguration calls, the same public API `scutil --nc` uses. It doesn't see profile-installed IKEv2 VPNs.
enum SystemConfigurationVPN {
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
    }

    static func status(id: String) -> VPNConnectionStatus {
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil) else { return .invalid }
        return VPNConnectionStatus(SCNetworkConnectionGetStatus(connection))
    }

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
