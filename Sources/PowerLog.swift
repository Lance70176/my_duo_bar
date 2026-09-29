import Foundation
import IOKit

/// One reading of the power flow: what the adapter is rated for, what the Mac draws from it, and where it goes.
/// Read from the `AppleSmartBattery` registry entry, the same figures AlDente and coconutBattery show.
struct PowerSample: Equatable, Sendable {
    var date: Date
    /// The adapter's rating in watts; nil when no adapter is connected.
    var adapterWatts: Int?
    var adapterVolts: Double?
    var adapterAmps: Double?
    /// Power drawn from the adapter (`SystemPowerIn`).
    var inputWatts: Double = 0
    var inputVolts: Double = 0
    var inputAmps: Double = 0
    /// Into the battery when positive, out of it when negative.
    var batteryWatts: Double = 0
    /// What the Mac itself uses (`SystemLoad`).
    var systemWatts: Double = 0
    var percent: Int?
    /// The registry's own update stamp. macOS refreshes these figures about every 30 seconds.
    var updateTime: Int64?

    var connected: Bool { adapterWatts != nil }

    /// Whether this reading carries anything `previous` did not: a registry update or a plug change.
    func isNew(after previous: PowerSample?) -> Bool {
        guard let previous, let updateTime, previous.updateTime != nil else { return true }
        return updateTime != previous.updateTime || connected != previous.connected
    }
}

protocol PowerReading: Sendable {
    /// Reads the power flow; nil when the Mac has no built-in battery. Cheap: one registry read.
    func read() -> PowerSample?
}

struct SystemPowerReader: PowerReading {
    func read() -> PowerSample? { PowerReader.read() }
}

enum PowerReader {
    static func read(date: Date = Date()) -> PowerSample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return parse(registry: dict, date: date)
    }

    /// Adapter rating from `AdapterDetails` (W, mV, mA), live input and system load from `PowerTelemetryData`
    /// (mW, mV, mA) and the battery's own voltage times its signed current.
    static func parse(registry dict: [String: Any], date: Date) -> PowerSample? {
        if let installed = dict["BatteryInstalled"] as? Bool, !installed { return nil }
        var sample = PowerSample(date: date)
        sample.updateTime = int(dict["UpdateTime"])
        let connected = dict["ExternalConnected"] as? Bool ?? false
        if connected, let adapter = dict["AdapterDetails"] as? [String: Any], let watts = int(adapter["Watts"]), watts > 0 {
            sample.adapterWatts = Int(watts)
            sample.adapterVolts = int(adapter["AdapterVoltage"]).map { Double($0) / 1000 }
            sample.adapterAmps = int(adapter["Current"]).map { Double($0) / 1000 }
        }
        let telemetry = dict["PowerTelemetryData"] as? [String: Any] ?? [:]
        if sample.connected {
            sample.inputWatts = Double(int(telemetry["SystemPowerIn"]) ?? 0) / 1000
            sample.inputVolts = Double(int(telemetry["SystemVoltageIn"]) ?? 0) / 1000
            sample.inputAmps = Double(int(telemetry["SystemCurrentIn"]) ?? 0) / 1000
        }
        sample.systemWatts = Double(int(telemetry["SystemLoad"]) ?? 0) / 1000
        if let volts = int(dict["Voltage"]), let amps = int(dict["Amperage"]) {
            sample.batteryWatts = Double(volts) * Double(amps) / 1_000_000
        }
        if let current = int(dict["CurrentCapacity"]), let maximum = int(dict["MaxCapacity"]), maximum > 0 {
            sample.percent = max(0, min(100, Int((Double(current) / Double(maximum) * 100).rounded())))
        }
        return sample
    }

    /// Registry numbers can arrive as unsigned 64-bit values; a negative current wraps, so keep the bit pattern.
    private static func int(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
}

/// The power log on disk: one CSV line per sample, readable in Numbers or Excel.
enum PowerLogFile {
    static let header = "time,adapter_w,input_w,input_v,input_a,battery_w,system_w,percent"
    /// Past this size the oldest half is dropped (about a week of charging at one line per 10 seconds).
    static let maxBytes = 4_000_000

    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MyDuoBar", isDirectory: true).appendingPathComponent("PowerLog.csv")
    }

    /// Local time as "2026-09-30 14:05:10", which spreadsheets read as a date.
    static func time(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func date(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { "- :".contains($0) }).compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                          hour: parts[3], minute: parts[4], second: parts[5]))
    }

    static func line(_ sample: PowerSample) -> String {
        func number(_ value: Double) -> String { String(format: "%.2f", value) }
        return [time(sample.date),
                sample.adapterWatts.map(String.init) ?? "",
                number(sample.inputWatts), number(sample.inputVolts), number(sample.inputAmps),
                number(sample.batteryWatts), number(sample.systemWatts),
                sample.percent.map(String.init) ?? ""].joined(separator: ",")
    }

    static func parse(line: String) -> PowerSample? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 8, let date = date(fields[0]) else { return nil }
        return PowerSample(date: date, adapterWatts: Int(fields[1]), inputWatts: Double(fields[2]) ?? 0,
                           inputVolts: Double(fields[3]) ?? 0, inputAmps: Double(fields[4]) ?? 0,
                           batteryWatts: Double(fields[5]) ?? 0, systemWatts: Double(fields[6]) ?? 0, percent: Int(fields[7]))
    }

    static func append(_ samples: [PowerSample], to url: URL) {
        guard !samples.isEmpty else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: Data((header + "\n").utf8)) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(samples.map { line($0) + "\n" }.joined().utf8))
    }

    /// The samples newer than `since`, oldest first. Trims the file first when it has grown too large.
    static func load(from url: URL, since: Date) -> [PowerSample] {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        if text.utf8.count > maxBytes {
            let lines = text.split(separator: "\n").dropFirst()
            text = ([header] + lines.suffix(lines.count / 2).map(String.init)).joined(separator: "\n") + "\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return text.split(separator: "\n").reversed().lazy
            .compactMap { parse(line: String($0)) }.prefix { $0.date >= since }.reversed()
    }
}

/// Checks the power flow every `interval` seconds and keeps each new reading (macOS refreshes about every
/// 30 seconds) for the chart; readings on adapter power, plus the first one after unplugging, go to the CSV log.
@MainActor
final class PowerLogger {
    static let interval: TimeInterval = 10
    /// The time the chart spans, ending now.
    static let chartSpan: TimeInterval = 2 * 3600
    /// How much history stays in memory: the chart's span plus a margin so its left edge is never empty.
    static let keep: TimeInterval = chartSpan + 600

    let reader: PowerReading
    let fileURL: URL?
    private(set) var samples: [PowerSample] = []
    private(set) var latest: PowerSample?
    private(set) var loaded = false
    var onSample: (() -> Void)?
    private var timer: Timer?
    private let worker = DispatchQueue(label: "com.rex.myduobar.power", qos: .utility)

    init(reader: PowerReading = SystemPowerReader(), fileURL: URL? = PowerLogFile.defaultURL) {
        self.reader = reader
        self.fileURL = fileURL
    }

    /// Loads the recent log, then samples on a timer until `stop()`.
    func start() {
        guard timer == nil else { return }
        let url = fileURL, since = Date().addingTimeInterval(-Self.keep)
        worker.async { [weak self] in
            let history = url.map { PowerLogFile.load(from: $0, since: since) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.samples = history + self.samples
                    self.sample()
                }
            }
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Takes one reading now, off the main thread. A reading macOS has not refreshed since the last one is dropped.
    func sample() {
        let reader = self.reader, url = fileURL, previous = latest
        worker.async { [weak self] in
            let fresh = reader.read()
            if let fresh, !fresh.isNew(after: previous) { return }
            if let fresh, let url, fresh.connected || previous?.connected == true { PowerLogFile.append([fresh], to: url) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(fresh) } }
        }
    }

    func record(_ fresh: PowerSample?) {
        loaded = true
        latest = fresh
        if let fresh {
            samples.append(fresh)
            let cutoff = fresh.date.addingTimeInterval(-Self.keep)
            if let first = samples.firstIndex(where: { $0.date >= cutoff }), first > 0 { samples.removeFirst(first) }
        }
        onSample?()
    }
}
