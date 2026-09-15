import Foundation
import ObjectiveC
import Synchronization

/// The charge limit macOS manages (System Settings → Battery → Charge Limit). `limit` is 100 when off.
struct ChargeLimitState: Equatable, Sendable {
    var supported = false
    var enabled = false
    var limit = 100
    /// The levels macOS offers below 100, e.g. 80, 85, 90, 95.
    var levels: [Int] = []

    static let unsupported = ChargeLimitState()
    /// The limit charging stops at, or nil when the limit is off or unavailable.
    var activeLimit: Int? { supported && enabled && limit < 100 ? limit : nil }
}

/// The charge-limit calls the Battery submenu needs; `SystemChargeLimitService` is the real one.
protocol ChargeLimitServing: Sendable {
    func read() -> ChargeLimitState
    func setLimit(_ percent: Int) -> Bool
    func disable() -> Bool
}

struct SystemChargeLimitService: ChargeLimitServing {
    func read() -> ChargeLimitState { ChargeLimitService.read() }
    func setLimit(_ percent: Int) -> Bool { ChargeLimitService.setLimit(percent) }
    func disable() -> Bool { ChargeLimitService.disable() }
}

/// Reads and sets the manual charge limit through PowerUI, the framework the Battery settings pane and
/// the system battery menu use. It talks to the same powerd policy, so the limit set here is the one
/// System Settings shows, persists across relaunches of this app, and needs no administrator rights.
/// PowerUI is not public API: it is looked up at runtime and everything reports "unsupported" when
/// the framework, the class or a method is missing. Safe to call from a background queue.
enum ChargeLimitService {
    static let clientName = "MyDuoBar"
    private static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    private static let className = "PowerUISmartChargeClient"

    private typealias ErrorOut = UnsafeMutablePointer<Unmanaged<NSError>?>?
    private typealias InitFunction = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
    private typealias BoolFunction = @convention(c) (AnyObject, Selector) -> Bool
    private typealias ObjectWithErrorFunction = @convention(c) (AnyObject, Selector, ErrorOut) -> AnyObject?
    private typealias UInt64WithErrorFunction = @convention(c) (AnyObject, Selector, ErrorOut) -> UInt64
    private typealias UInt8WithErrorFunction = @convention(c) (AnyObject, Selector, ErrorOut) -> UInt8
    private typealias BoolWithErrorFunction = @convention(c) (AnyObject, Selector, ErrorOut) -> Bool
    private typealias SetUInt8Function = @convention(c) (AnyObject, Selector, UInt8, ErrorOut) -> Bool

    /// One client for the process, created on first use. Calls are serialized: the client is an XPC proxy.
    private final class Client: @unchecked Sendable {
        let object: AnyObject
        init(object: AnyObject) { self.object = object }
    }
    private enum Slot { case untried, unavailable, ready(Client) }
    private static let slot = Mutex<Slot>(.untried)

    private static func selector(_ name: String) -> Selector { NSSelectorFromString(name) }

    private static func implementation<T>(_ object: AnyObject, _ name: String, _ type: T.Type) -> T? {
        guard let cls = object_getClass(object), let method = class_getInstanceMethod(cls, selector(name)) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: T.self)
    }

    /// Runs a call that takes an `NSError **`; a reported error turns the result into nil.
    private static func checked<T>(_ body: (ErrorOut) -> T) -> T? {
        var error: Unmanaged<NSError>? = nil
        let result = body(&error)
        return error == nil ? result : nil
    }

    private static func makeClient() -> Client? {
        guard dlopen(frameworkPath, RTLD_NOW) != nil, let cls = NSClassFromString(className) else { return nil }
        for required in ["isMCLSupported", "availableChargeLimitsWithError:", "isMCLCurrentlyEnabled:", "getMCLLimitWithError:", "setMCLLimit:error:", "disableMCL:"]
        where class_getInstanceMethod(cls, selector(required)) == nil { return nil }
        guard let allocated = (cls as AnyObject).perform(selector("alloc"))?.takeUnretainedValue(),
              let initialize = implementation(allocated, "initWithClientName:", InitFunction.self),
              let object = initialize(allocated, selector("initWithClientName:"), clientName as NSString) else { return nil }
        return Client(object: object)
    }

    /// Runs `body` with the client, or returns `fallback` when PowerUI is unavailable on this Mac.
    private static func withClient<T: Sendable>(_ fallback: T, _ body: (AnyObject) -> T) -> T {
        slot.withLock { slot -> T in
            if case .untried = slot { slot = makeClient().map { .ready($0) } ?? .unavailable }
            guard case .ready(let client) = slot else { return fallback }
            return body(client.object)
        }
    }

    static func read() -> ChargeLimitState {
        withClient(.unsupported) { object in
            guard let isSupported = implementation(object, "isMCLSupported", BoolFunction.self),
                  let isEnabled = implementation(object, "isMCLCurrentlyEnabled:", UInt64WithErrorFunction.self),
                  let currentLimit = implementation(object, "getMCLLimitWithError:", UInt8WithErrorFunction.self),
                  let offeredLimits = implementation(object, "availableChargeLimitsWithError:", ObjectWithErrorFunction.self),
                  isSupported(object, selector("isMCLSupported")),
                  let enabled = checked({ isEnabled(object, selector("isMCLCurrentlyEnabled:"), $0) }),
                  let limit = checked({ currentLimit(object, selector("getMCLLimitWithError:"), $0) }) else { return .unsupported }
            let offered = (checked({ offeredLimits(object, selector("availableChargeLimitsWithError:"), $0) }) as? [NSNumber])?.map(\.intValue) ?? []
            return ChargeLimitState(supported: true, enabled: enabled != 0, limit: Int(limit),
                                    levels: offered.filter { (1..<100).contains($0) }.sorted())
        }
    }

    /// Turns the limit on at `percent`. Returns false when macOS refused or the value is out of range.
    static func setLimit(_ percent: Int) -> Bool {
        guard (1...100).contains(percent) else { return false }
        return withClient(false) { object in
            guard let set = implementation(object, "setMCLLimit:error:", SetUInt8Function.self) else { return false }
            return checked({ set(object, selector("setMCLLimit:error:"), UInt8(percent), $0) }) == true
        }
    }

    static func disable() -> Bool {
        withClient(false) { object in
            guard let disable = implementation(object, "disableMCL:", BoolWithErrorFunction.self) else { return false }
            return checked({ disable(object, selector("disableMCL:"), $0) }) == true
        }
    }
}
