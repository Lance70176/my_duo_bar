import Foundation
import IOKit.pwr_mgt
import Synchronization

/// The calls the Keep Awake submenu needs; `SystemSleepService` is the real one.
protocol SleepGuarding: Sendable {
    /// Holds the Mac awake, and the display too when asked. Replaces any earlier hold. False when macOS refused.
    func start(keepDisplayOn: Bool) -> Bool
    func stop()
}

struct SystemSleepService: SleepGuarding {
    func start(keepDisplayOn: Bool) -> Bool { SleepService.start(keepDisplayOn: keepDisplayOn) }
    func stop() { SleepService.stop() }
}

/// Keeps the Mac awake with IOKit power assertions, the public API `caffeinate` uses. The assertions
/// only stop idle sleep: closing the lid or choosing Sleep still works. They end when this app releases
/// them or quits, and nothing in System Settings is changed.
enum SleepService {
    private static let held = Mutex<[IOPMAssertionID]>([])

    static func start(keepDisplayOn: Bool) -> Bool {
        stop()
        var types = [kIOPMAssertionTypePreventUserIdleSystemSleep]
        if keepDisplayOn { types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep) }
        var ids: [IOPMAssertionID] = []
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "MyDuoBar Keep Awake" as CFString, &id)
            if result == kIOReturnSuccess { ids.append(id) }
        }
        held.withLock { $0 = ids }
        return !ids.isEmpty
    }

    static func stop() {
        held.withLock { ids in
            for id in ids { _ = IOPMAssertionRelease(id) }
            ids = []
        }
    }

    static var isHolding: Bool { held.withLock { !$0.isEmpty } }
}
