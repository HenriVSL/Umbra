import Foundation
import UmbraCore
import UmbraNet

/// Works out the address internet clients should dial, for the invite QR.
public enum PublicAddress {
    public struct Detected: Sendable, Equatable {
        public let address: String
        /// Where it came from: "interface", or the STUN server that reported it (meaning we are behind NAT).
        public let source: String
        public var behindNAT: Bool { source != "interface" }
    }

    public static let stunServers: [(host: String, port: Int)] = [
        ("stun.cloudflare.com", 3478),
        ("stun.l.google.com", 19302),
    ]

    /// A public address on a local interface (a typical VPS) needs no network traffic at all.
    /// Otherwise, if `allowSTUN`, asks STUN servers which address our packets arrive from.
    public static func detect(allowSTUN: Bool, timeout: Double = 3) async -> Detected? {
        if let address = NetworkInterfaces.lanIPv4().first(where: isPublic) {
            return Detected(address: address, source: "interface")
        }
        guard allowSTUN else { return nil }
        for server in stunServers {
            if let address = try? await withDeadline(seconds: timeout, { try await stun(server.host, port: server.port) }),
               isPublic(address) {
                return Detected(address: address, source: server.host)
            }
        }
        return nil
    }

    /// False for private, carrier-grade NAT, loopback, link-local, documentation and multicast ranges.
    public static func isPublic(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let (a, b, c) = (parts[0], parts[1], parts[2])
        switch (a, b, c) {
        case (0, _, _), (10, _, _), (127, _, _): return false
        case (100, 64...127, _): return false
        case (169, 254, _): return false
        case (172, 16...31, _): return false
        case (192, 0, 0), (192, 0, 2), (192, 168, _): return false
        case (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false
        case (224..., _, _): return false
        default: return true
        }
    }

    // MARK: STUN (RFC 5389): one Binding request over UDP

    private static let magicCookie: UInt32 = 0x2112_A442

    static func stun(_ host: String, port: Int) async throws -> String {
        guard let ip = NetworkInterfaces.resolveIPv4(host) else { throw UmbraError.malformed }
        let remote = try SocketAddress(ipAddress: ip, port: port)
        let transaction = Data.random(12)
        var request = ByteBuffer()
        request.writeInteger(UInt16(0x0001))  // Binding request
        request.writeInteger(UInt16(0))       // no attributes
        request.writeInteger(magicCookie)
        request.writeBytes(transaction)

        typealias Datagrams = NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>
        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "0.0.0.0", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture { try Datagrams(wrappingChannelSynchronously: channel) }
            }
        return try await channel.executeThenClose { inbound, outbound in
            // UDP may drop a packet; a second copy costs nothing (same transaction).
            for _ in 0..<2 { try await outbound.write(AddressedEnvelope(remoteAddress: remote, data: request)) }
            for try await reply in inbound {
                if let address = parseBindingResponse(Data(reply.data.readableBytesView), transaction: transaction) {
                    return address
                }
            }
            throw UmbraError.malformed
        }
    }

    /// The IPv4 address in a Binding success response, preferring XOR-MAPPED-ADDRESS.
    static func parseBindingResponse(_ data: Data, transaction: Data) -> String? {
        let data = Data(data)
        guard data.count >= 20, data.readBE(UInt16.self, at: 0) == 0x0101,
              data.readBE(UInt32.self, at: 4) == magicCookie, data.subdata(in: 8..<20) == transaction
        else { return nil }
        var mapped: String?
        var offset = 20
        while offset + 4 <= data.count, let type = data.readBE(UInt16.self, at: offset),
              let length = data.readBE(UInt16.self, at: offset + 2).map(Int.init) {
            let value = offset + 4
            guard value + length <= data.count else { break }
            if length >= 8, data[value + 1] == 0x01 {  // IPv4
                let raw = Array(data[(value + 4)..<(value + 8)])
                if type == 0x0020 {
                    let cookie = withUnsafeBytes(of: magicCookie.bigEndian, Array.init)
                    return zip(raw, cookie).map { String($0 ^ $1) }.joined(separator: ".")
                }
                if type == 0x0001 { mapped = raw.map(String.init).joined(separator: ".") }
            }
            offset = value + (length + 3) / 4 * 4
        }
        return mapped
    }
}
