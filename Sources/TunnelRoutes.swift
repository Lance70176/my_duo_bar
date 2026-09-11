import Foundation
import Darwin

/// Active catch-all routes distinguish a real VPN/TUN path from idle Apple utun interfaces.
struct IPv4TunnelRoute {
    let interface: String
    let destination: UInt32
    let mask: UInt32
    let usable: Bool
}

enum TunnelRoutePolicy {
    static func activeInterfaces(_ routes: [IPv4TunnelRoute]) -> [String] {
        let grouped = Dictionary(grouping: routes.filter { $0.usable && $0.interface.hasPrefix("utun") }, by: \.interface)
        return grouped.compactMap { interface, entries in
            let ranges = entries.map { entry -> (UInt64, UInt64) in
                let start = UInt64(entry.destination & entry.mask)
                return (start, start + UInt64(~entry.mask) + 1)
            }.sorted { $0.0 < $1.0 }
            var total: UInt64 = 0
            var current: (UInt64, UInt64)?
            for range in ranges {
                if let c = current {
                    if range.0 <= c.1 { current = (c.0, max(c.1, range.1)) }
                    else { total += c.1 - c.0; current = range }
                } else { current = range }
            }
            if let c = current { total += c.1 - c.0 }
            // Mihomo excludes special ranges and installs 1/8, 2/7, …, 128/1.
            // A single host route or link-local tunnel never reaches this threshold.
            return total >= (UInt64(1) << 31) ? interface : nil
        }.sorted()
    }
}

enum TunnelRoutes {
    static func ipv4Value(_ sockaddr: [UInt8], isMask: Bool) -> UInt32? {
        guard let length = sockaddr.first else { return nil }
        if isMask && length == 0 { return 0 }
        guard sockaddr.count >= Int(length), length >= 4,
              isMask || (length >= 8 && sockaddr[1] == UInt8(AF_INET)) else { return nil }
        // Darwin netmasks are bit masks, including sa_family=255, and omit trailing zeros.
        return (4..<8).reduce(UInt32(0)) { value, offset in
            (value << 8) | (offset < Int(length) ? UInt32(sockaddr[offset]) : 0)
        }
    }
    static func read() -> [IPv4TunnelRoute] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return [] }
        return buffer.withUnsafeBytes { bytes in
            var offset = 0
            var routes: [IPv4TunnelRoute] = []
            while offset + MemoryLayout<rt_msghdr2>.size <= size {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: rt_msghdr2.self)
                let length = Int(header.rtm_msglen)
                guard length >= MemoryLayout<rt_msghdr2>.size, offset + length <= size else { break }
                var cursor = offset + MemoryLayout<rt_msghdr2>.size
                var destination: UInt32?
                var mask: UInt32?
                for slot in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << slot) != 0 {
                    guard cursor + 2 <= offset + length else { break }
                    let count = Int(bytes[cursor])
                    if slot == Int(RTAX_DST) || slot == Int(RTAX_NETMASK) {
                        if cursor + max(1, count) <= offset + length {
                            let raw = Array(bytes[cursor..<cursor + max(1, count)])
                            if slot == Int(RTAX_DST) { destination = ipv4Value(raw, isMask: false) }
                            else { mask = ipv4Value(raw, isMask: true) }
                        }
                    }
                    cursor += count == 0 ? 4 : (count + 3) & ~3
                }
                if let destination {
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(header.rtm_index), &name) != nil {
                        let interface = String(cString: name)
                        let up = header.rtm_flags & RTF_UP != 0
                        let scoped = header.rtm_flags & RTF_IFSCOPE != 0
                        routes.append(IPv4TunnelRoute(interface: interface, destination: destination,
                            mask: mask ?? (destination == 0 ? 0 : UInt32.max), usable: up && !scoped))
                    }
                }
                offset += length
            }
            return routes
        }
    }
}
