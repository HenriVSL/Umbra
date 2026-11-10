import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl  // the fully static Linux build
#elseif canImport(Darwin)
import Darwin
#endif

public enum NetworkInterfaces {
    // Same values on Linux and Darwin; literal so the code compiles identically on both.
    private static let flagUp: UInt32 = 0x1
    private static let flagLoopback: UInt32 = 0x8
    /// Cellular, VPN tunnels and Apple-private links are useless as a LAN address in a QR code.
    private static let ignoredPrefixes = ["pdp_ip", "utun", "ipsec", "llw", "awdl", "anpi", "ap", "docker", "veth",
                                         "br-", "virbr", "lxcbr", "cni", "flannel"]
    private static let preferred = ["en0", "en1", "eth0", "wlan0", "bridge100"]

    /// IPv4 addresses of LAN interfaces that are up, Wi-Fi/Ethernet/hotspot first.
    public static func lanIPv4() -> [String] {
        var result: [(name: String, address: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = UInt32(truncatingIfNeeded: ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET,
                  flags & flagUp != 0, flags & flagLoopback == 0
            else { continue }
            let name = decode(ifa.ifa_name)
            guard !ignoredPrefixes.contains(where: name.hasPrefix) || preferred.contains(name) else { continue }
            var host = [CChar](repeating: 0, count: 1025)
            guard getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            result.append((name, decode(host)))
        }
        return result.sorted { a, b in
            (preferred.firstIndex(of: a.name) ?? 99) < (preferred.firstIndex(of: b.name) ?? 99)
        }.map(\.address)
    }

    /// First IPv4 address for a host name (blocking DNS lookup).
    public static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &results) == 0, let first = results else { return nil }
        defer { freeaddrinfo(results) }
        guard let addr = first.pointee.ai_addr else { return nil }
        var name = [CChar](repeating: 0, count: 1025)
        guard getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return decode(name)
    }

    private static func decode(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func decode(_ pointer: UnsafeMutablePointer<CChar>) -> String {
        decode(Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer))))
    }
}
