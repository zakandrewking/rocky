import Foundation

/// Shared by RobotDiscovery and DeviceAPIDiscovery -- both need to know the phone's own /24 to
/// sweep, and there's exactly one honest way to get it.
enum NetworkUtilities {
    /// The phone's IPv4 on Wi-Fi (en0), as "a.b.c." -- the /24 to sweep. getifaddrs is plain
    /// POSIX, no entitlement needed. nil on cellular-only or no Wi-Fi, which just means no scan.
    static func localSubnetPrefix() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                String(cString: current.pointee.ifa_name) == "en0"
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".")
            guard octets.count == 4 else { continue }
            return "\(octets[0]).\(octets[1]).\(octets[2])."
        }
        return nil
    }
}
