import Foundation

/// Bytes received and sent per second across the physical network interfaces.
struct NetworkSpeed: Equatable {
    var download: Double = 0
    var upload: Double = 0

    /// A compact rate for the menu bar, in decimal units like Activity Monitor: "8 KB/s", "1.2 MB/s", "35 MB/s".
    static func format(_ bytesPerSecond: Double) -> String {
        let kilobytes = max(0, bytesPerSecond) / 1000
        if kilobytes < 999.5 { return "\(Int(kilobytes.rounded())) KB/s" }
        let megabytes = kilobytes / 1000
        if megabytes < 9.95 { return String(format: "%.1f MB/s", megabytes) }
        if megabytes < 999.5 { return "\(Int(megabytes.rounded())) MB/s" }
        return String(format: "%.1f GB/s", megabytes / 1000)
    }
}

/// Per-interface byte counters, as the kernel reports them.
struct InterfaceCounters: Equatable {
    var received: [String: UInt32] = [:]
    var sent: [String: UInt32] = [:]

    /// Counts only Ethernet-style interfaces (en0 is Wi-Fi on every Mac), so VPN tunnels are not counted twice.
    static func read() -> InterfaceCounters {
        var counters = InterfaceCounters()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return counters }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            counters.received[name] = data.pointee.ifi_ibytes
            counters.sent[name] = data.pointee.ifi_obytes
        }
        return counters
    }

    /// The rate since `previous`. The kernel's counters are 32-bit, so wrapping subtraction survives a rollover;
    /// an interface that appeared in between contributes nothing until the next sample.
    func speed(since previous: InterfaceCounters, seconds: TimeInterval) -> NetworkSpeed {
        guard seconds > 0 else { return NetworkSpeed() }
        func delta(_ now: [String: UInt32], _ old: [String: UInt32]) -> Double {
            now.reduce(0) { total, item in
                guard let before = old[item.key] else { return total }
                return total + Double(item.value &- before)
            }
        }
        return NetworkSpeed(download: delta(received, previous.received) / seconds,
                            upload: delta(sent, previous.sent) / seconds)
    }
}

/// Samples the counters once a second while enabled; stops while the Mac sleeps.
@MainActor
final class NetworkSpeedMonitor {
    var onChange: ((NetworkSpeed) -> Void)?
    private(set) var speed = NetworkSpeed()
    private var timer: Timer?
    private var last: (counters: InterfaceCounters, time: TimeInterval)?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        last = (InterfaceCounters.read(), ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil; last = nil
        if speed != NetworkSpeed() { speed = NetworkSpeed(); onChange?(speed) }
    }

    private func sample() {
        let counters = InterfaceCounters.read()
        let now = ProcessInfo.processInfo.systemUptime
        if let last { speed = counters.speed(since: last.counters, seconds: now - last.time) }
        last = (counters, now)
        onChange?(speed)
    }
}
