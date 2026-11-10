import Foundation
import UmbraCore
import UmbraNet

/// One connection to a relay server.
///
/// `session` connects, authenticates the server against its pinned key, then runs until the
/// connection drops or the calling task is cancelled. Frames to send are pulled from `outgoing`;
/// every frame received is passed to `incoming`. Callers own reconnection policy.
public enum RelayClient {
    public static func session(
        server: ServerInfo,
        outgoing: AsyncStream<ClientFrame>,
        connectTimeout: Double = 10,
        incoming: @escaping @Sendable (ServerFrame) async -> Void
    ) async throws {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.milliseconds(Int64(connectTimeout * 1000)))
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .connect(host: server.host, port: server.port) { $0.makeFrameChannel() }

        try await channel.executeThenClose { inbound, outbound in
            let frames = UncheckedBox(inbound.makeAsyncIterator())
            let (hello, state) = try Handshake.clientStart(serverKey: server.publicKey, psk: server.accessKey)
            try await outbound.write(.frame(hello))
            guard let reply = try await withDeadline(seconds: connectTimeout, { try await frames.value.next() }) else {
                throw UmbraError.handshakeFailed
            }
            let secure = try Handshake.clientFinish(state, response: reply.data)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var sender = secure
                    // Something must be sent first so the server can verify our keys; a ping is harmless.
                    try await outbound.write(.frame(try sender.seal(try WireCodec.encode(ClientFrame.ping))))
                    for await frame in outgoing {
                        try await outbound.write(.frame(try sender.seal(try WireCodec.encode(frame))))
                    }
                }
                group.addTask {
                    var receiver = secure
                    var authenticated = false
                    while let next = try await frames.value.next() {
                        await incoming(try WireCodec.decode(ServerFrame.self, from: try receiver.open(next.data)))
                        authenticated = true
                    }
                    // Servers silently drop clients with the wrong access key: closing before any frame means rejection.
                    if !authenticated { throw UmbraError.handshakeFailed }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }
    }
}
