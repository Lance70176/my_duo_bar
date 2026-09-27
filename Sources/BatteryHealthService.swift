import Foundation
import IOKit

/// How worn the built-in battery is: the maximum capacity and condition System Settings shows, and the
/// cycle count. Read-only; nothing here changes the battery or the system.
struct BatteryHealth: Equatable, Sendable {
    enum Condition: Equatable, Sendable {
        case normal
        case serviceRecommended
        case unknown
    }
    /// Full charge as a percentage of the design capacity, macOS's own figure when available.
    var maximumCapacity: Int?
    var condition: Condition = .unknown
    var cycleCount: Int?
    /// The cycle count the battery is rated for, when the pack reports it.
    var designCycleCount: Int?

    /// The maximum-capacity line, e.g. "最大容量 84% · 正常".
    var capacityLine: String {
        guard let maximumCapacity else { return L10n.reading }
        let capacity = L10n.maximumCapacity(maximumCapacity)
        switch condition {
        case .normal: return capacity + " · " + L10n.conditionNormal
        case .serviceRecommended: return capacity + " · " + L10n.conditionServiceRecommended
        case .unknown: return capacity
        }
    }
    /// The cycle-count line, e.g. "循環次數 239（設計 1000）".
    var cycleLine: String {
        guard let cycleCount else { return L10n.reading }
        return L10n.cycleCount(cycleCount, design: designCycleCount)
    }
}

protocol BatteryHealthReading: Sendable {
    /// Reads the health; nil when the Mac has no built-in battery. Runs a helper, so keep it off the main thread.
    func read() -> BatteryHealth?
}

struct SystemBatteryHealthService: BatteryHealthReading {
    func read() -> BatteryHealth? { BatteryHealthService.read() }
}

/// Two sources: the IORegistry battery entry (instant: cycle counts and pack capacities) and
/// `system_profiler`, which reports the same maximum capacity and condition as System Settings.
/// Without the profiler the capacity is estimated from the pack's own figures.
enum BatteryHealthService {
    static func read() -> BatteryHealth? {
        guard var health = registry() else { return nil }
        if let profile = profiler() { health.merge(profile) }
        return health
    }

    /// The `AppleSmartBattery` registry entry; nil when there is none (no built-in battery).
    static func registry() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return parse(registry: dict)
    }

    /// Cycle counts from the entry and a capacity estimate from the pack's nominal full charge
    /// against its design capacity (the pack nests these in `BatteryData` on Apple silicon).
    static func parse(registry dict: [String: Any]) -> BatteryHealth? {
        if let installed = dict["BatteryInstalled"] as? Bool, !installed { return nil }
        var health = BatteryHealth()
        health.cycleCount = int(dict["CycleCount"])
        health.designCycleCount = int(dict["DesignCycleCount9C"])
        let pack = dict["BatteryData"] as? [String: Any] ?? [:]
        let design = int(pack["DesignCapacity"]) ?? int(dict["DesignCapacity"])
        let full = int(pack["NominalChargeCapacity"]) ?? int(dict["NominalChargeCapacity"]) ?? int(dict["AppleRawMaxCapacity"])
        if let design, design > 0, let full, full > 0 {
            health.maximumCapacity = min(100, Int((Double(full) / Double(design) * 100).rounded()))
        }
        return health
    }

    /// `system_profiler SPPowerDataType` as JSON; nil when it fails or takes too long.
    static func profiler(timeout: TimeInterval = 8) -> BatteryHealth? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPPowerDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return parse(profile: data)
    }

    /// The health section of the profiler's JSON: "sppower_battery_health_maximum_capacity" ("84%"),
    /// "sppower_battery_health" ("Good", otherwise service is due) and "sppower_battery_cycle_count".
    static func parse(profile data: Data) -> BatteryHealth? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]],
              let info = entries.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first else { return nil }
        var health = BatteryHealth()
        if let text = info["sppower_battery_health_maximum_capacity"] as? String {
            health.maximumCapacity = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        if let condition = (info["sppower_battery_health"] as? String)?.trimmingCharacters(in: .whitespaces), !condition.isEmpty {
            health.condition = ["good", "normal"].contains(condition.lowercased()) ? .normal : .serviceRecommended
        }
        health.cycleCount = int(info["sppower_battery_cycle_count"])
        return health
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

extension BatteryHealth {
    /// Takes the profiler's figures over the registry estimate; the registry keeps what the profiler lacks.
    mutating func merge(_ profile: BatteryHealth) {
        if let percent = profile.maximumCapacity { maximumCapacity = percent }
        if profile.condition != .unknown { condition = profile.condition }
        if cycleCount == nil { cycleCount = profile.cycleCount }
    }
}
