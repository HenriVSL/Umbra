#if canImport(dnssd)
import dnssd
import Foundation
import UmbraCore

/// Announces a running server on the local network via Bonjour, so clients that already hold its
/// invite can find it after its IP address changes. Only an opaque discovery ID is published:
/// no server name, key or access key.
public final class Announcer: @unchecked Sendable {
    private var ref: DNSServiceRef?
    private let queue = DispatchQueue(label: "umbra.announcer")

    public init?(publicKey: Data, port: Int) {
        let id = ServerInfo.discoveryID(for: publicKey)
        let entry = Array("id=\(id)".utf8)
        let txt = [UInt8(entry.count)] + entry
        let name = "umbra-" + id.prefix(6)
        var ref: DNSServiceRef?
        let status = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &ref, 0, 0, name, ServerInfo.bonjourType, nil, nil, UInt16(port).bigEndian,
                UInt16(bytes.count), bytes.baseAddress, nil, nil)
        }
        guard status == kDNSServiceErr_NoError, let ref else { return nil }
        DNSServiceSetDispatchQueue(ref, queue)
        self.ref = ref
    }

    public func stop() {
        guard let ref else { return }
        self.ref = nil
        queue.sync { DNSServiceRefDeallocate(ref) }
    }

    deinit { stop() }
}
#endif
