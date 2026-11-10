import Foundation
import UmbraCore
import UmbraNet

public struct RelayConfiguration: Sendable {
    public var name: String
    public var host: String
    public var port: Int
    public var mode: ServerMode
    /// How long stored blobs live (store mode).
    public var retention: TimeInterval
    /// When set, only clients holding this key get any response at all.
    public var accessKey: Data?
    /// Store mode: keep an encrypted snapshot here so messages survive restarts. Nil keeps them in RAM only.
    public var snapshotURL: URL?
    public var maxBlobSize: Int
    /// Store mode: oldest blobs are evicted beyond this many bytes.
    public var maxStoredBytes: Int
    public var maxConnections: Int
    /// Connections silent for this long are closed (clients ping every 25 s).
    public var idleTimeout: TimeInterval

    public init(
        name: String = "Umbra", host: String = "0.0.0.0", port: Int = 7443, mode: ServerMode = .relay,
        retention: TimeInterval = 7 * 86_400, accessKey: Data? = nil, snapshotURL: URL? = nil,
        maxBlobSize: Int = 64 * 1024, maxStoredBytes: Int = 256 << 20, maxConnections: Int = 1024,
        idleTimeout: TimeInterval = 90
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.mode = mode
        self.retention = retention
        self.accessKey = accessKey
        self.snapshotURL = snapshotURL
        self.maxBlobSize = maxBlobSize
        self.maxStoredBytes = maxStoredBytes
        self.maxConnections = maxConnections
        self.idleTimeout = idleTimeout
    }
}

/// A relay server. Logs nothing: no addresses, no tags, no timing. Usable from the CLI and inside the app.
///
/// `start()` and `stop()` may be called repeatedly. Stored blobs live in the hub, which outlives the
/// listener, so an iOS host can rebind after being suspended without losing its store.
public actor RelayServer {
    public let configuration: RelayConfiguration
    public nonisolated let publicKey: Data
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let hub: RelayHub
    private var serveTask: Task<Void, Error>?
    private var maintenanceTask: Task<Void, Never>?
    private var serverChannel: Channel?
    private var snapshotLoaded = false
    public private(set) var boundPort: Int?

    public init(configuration: RelayConfiguration, privateKey: Data) throws {
        self.configuration = configuration
        staticKey = try .init(rawRepresentation: privateKey)
        publicKey = staticKey.publicKey.rawRepresentation
        hub = RelayHub(
            mode: configuration.mode, retention: configuration.retention,
            maxStoredBytes: configuration.maxStoredBytes, maxConnections: configuration.maxConnections)
    }

    public static func generatePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    /// Invite for this server, reachable at `host` (the address clients should dial).
    public nonisolated func invite(host: String, port: Int) -> Invite {
        .server(ServerInfo(
            name: configuration.name, host: host, port: port, publicKey: publicKey, accessKey: configuration.accessKey))
    }

    public var isRunning: Bool { serverChannel?.isActive ?? false }
    public var connectionCount: Int { get async { await hub.connectionCount } }

    /// Binds and starts serving in the background. Returns the bound port.
    @discardableResult
    public func start() async throws -> Int {
        if serveTask != nil { await stopListening() }
        if !snapshotLoaded {
            try await loadSnapshot()
            snapshotLoaded = true
        }

        let idle = TimeAmount.milliseconds(Int64(configuration.idleTimeout * 1000))
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .bind(host: configuration.host, port: boundPort ?? configuration.port) { $0.makeFrameChannel(idleTimeout: idle) }
        serverChannel = channel.channel
        let port = channel.channel.localAddress?.port ?? configuration.port
        boundPort = port

        let hub = hub, key = staticKey, config = configuration
        let epoch = await hub.epoch
        serveTask = Task {
            try await channel.executeThenClose { inbound in
                for try await connection in inbound {
                    // One task per connection, freed as soon as it ends (a discarding task group would
                    // do the same but needs iOS 17). Stopping ends them through the hub (see `epoch`).
                    Task { await Self.serve(connection, hub: hub, key: key, config: config, epoch: epoch) }
                }
            }
        }
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.maintenance()
            }
        }
        return port
    }

    public func stop() async {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        await stopListening()
        try? await saveSnapshot()
    }

    private func stopListening() async {
        await hub.disconnectAll()
        try? await serverChannel?.close()
        serverChannel = nil
        serveTask?.cancel()
        _ = try? await serveTask?.value
        serveTask = nil
    }

    /// Runs until the task is cancelled.
    public func run() async throws {
        try await start()
        let task = serveTask
        try await withTaskCancellationHandler {
            _ = try await task?.value
        } onCancel: {
            Task { await self.stop() }
        }
    }

    private func maintenance() async {
        await hub.purgeExpired()
        try? await saveSnapshot()
    }

    private static func serve(_ connection: FrameChannel, hub: RelayHub, key: Curve25519.KeyAgreement.PrivateKey, config: RelayConfiguration, epoch: Int) async {
        let id = UUID()
        // Any failure simply closes the connection. Nothing is reported or recorded.
        try? await connection.executeThenClose { inbound, outbound in
            let frames = UncheckedBox(inbound.makeAsyncIterator())

            // Handshake (must complete within 10 s). Without a valid access-key proof we never answer.
            guard let hello = try await withDeadline(seconds: 10, { try await frames.value.next() }) else { return }
            let (reply, secure) = try Handshake.serverRespond(to: hello.data, staticKey: key, psk: config.accessKey)
            try await outbound.write(.frame(reply))

            guard let first = try await withDeadline(seconds: 10, { try await frames.value.next() }) else { return }
            var receiver = secure
            let firstFrame = try WireCodec.decode(ClientFrame.self, from: try receiver.open(first.data))

            // Bounded: if a client cannot keep up, the hub closes it (see RelayHub.send) and it resyncs.
            let (stream, outbox) = AsyncStream.makeStream(
                of: ServerFrame.self, bufferingPolicy: .bufferingOldest(RelayHub.outboxDepth))
            guard await hub.connect(id, outbox: outbox, epoch: epoch) else { return }
            await hub.send(.welcome(
                name: config.name, mode: config.mode, retentionSeconds: Int(config.retention),
                instance: await hub.instance, cursor: await hub.cursor), to: id)

            // The writer copy only ever seals and the reader copy only ever opens, so each keeps its own counter.
            try await withThrowingTaskGroup(of: Void.self) { [receiver] group in
                group.addTask {
                    var sender = secure
                    for await frame in stream {
                        try await outbound.write(.frame(try sender.seal(try WireCodec.encode(frame))))
                    }
                }
                group.addTask {
                    var receiver = receiver
                    try await handle(firstFrame, id: id, hub: hub, config: config)
                    while let next = try await frames.value.next() {
                        let frame = try WireCodec.decode(ClientFrame.self, from: try receiver.open(next.data))
                        try await handle(frame, id: id, hub: hub, config: config)
                    }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }
        await hub.disconnect(id)
    }

    private static func handle(_ frame: ClientFrame, id: UUID, hub: RelayHub, config: RelayConfiguration) async throws {
        switch frame {
        case .subscribe(let request, let tags, let since):
            await hub.subscribe(id, request: request, tags: tags, since: since)
        case .unsubscribe(let tags):
            await hub.unsubscribe(id, tags: tags)
        case .publish(let ref, let tag, let blob):
            guard blob.count <= config.maxBlobSize else {
                await hub.send(.error("blob too large"), to: id)
                return
            }
            await hub.publish(from: id, ref: ref, tag: tag, blob: blob)
        case .ping:
            await hub.send(.pong, to: id)
        }
    }

    // MARK: Encrypted snapshot

    private var snapshotKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: staticKey.rawRepresentation),
            salt: Data(), info: Data("umbra/server/snapshot".utf8), outputByteCount: 32)
    }

    private func loadSnapshot() async throws {
        guard configuration.mode == .store, let url = configuration.snapshotURL,
              let sealed = try? Data(contentsOf: url)
        else { return }
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: snapshotKey)
        await hub.restore(try WireCodec.decode(RelayHub.Snapshot.self, from: plain))
    }

    private func saveSnapshot() async throws {
        guard configuration.mode == .store, let url = configuration.snapshotURL, await hub.dirty else { return }
        let plain = try WireCodec.encode(await hub.snapshot())
        let sealed = try ChaChaPoly.seal(plain, using: snapshotKey).combined
        try sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
