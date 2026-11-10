import Foundation
import Testing
import UmbraClient
import UmbraCore
@testable import UmbraServer

typealias RoutingTag = UmbraCore.Tag

/// Runs a client session in the background, driving a `SyncState` like the app does.
final class TestClient: @unchecked Sendable {
    let send: AsyncStream<ClientFrame>.Continuation
    let received: AsyncStream<ServerFrame>
    private let lock = NSLock()
    private var _sync: SyncState
    private var desired: Set<RoutingTag>

    var sync: SyncState { lock.withLock { _sync } }

    init(_ server: ServerInfo, tags: [RoutingTag] = [], sync: SyncState = SyncState()) {
        let (out, send) = AsyncStream.makeStream(of: ClientFrame.self)
        let (received, sink) = AsyncStream.makeStream(of: ServerFrame.self)
        self.send = send
        self.received = received
        _sync = sync
        desired = Set(tags)
        session = nil
        let client = self
        session = Task {
            defer { sink.finish() }
            try await RelayClient.session(server: server, outgoing: out) { frame in
                for reply in client.feed(frame) { send.yield(reply) }
                sink.yield(frame)
            }
        }
    }

    private(set) var session: Task<Void, Error>!

    private func feed(_ frame: ServerFrame) -> [ClientFrame] {
        lock.withLock {
            if case .welcome(_, let mode, _, let instance, _) = frame {
                return _sync.connected(mode: mode, instance: instance, desired: desired)
            }
            return _sync.received(frame)
        }
    }

    func want(_ tags: [RoutingTag]) {
        let frames = lock.withLock {
            desired.formUnion(tags)
            return _sync.update(desired: desired)
        }
        for f in frames { send.yield(f) }
    }

    /// Next frame matching `match`, or nil if the connection closes / `timeout` passes.
    func next<T: Sendable>(timeout: Double = 5, _ match: @escaping @Sendable (ServerFrame) -> T?) async -> T? {
        let stream = received
        return try? await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                for await frame in stream { if let v = match(frame) { return v } }
                return nil
            }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); return nil }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Collects delivered blobs until catch-up has finished and `count` were seen (or timeout).
    func collect(_ count: Int, timeout: Double = 5) async -> [Data] {
        let stream = received
        return (try? await withThrowingTaskGroup(of: [Data].self) { group in
            group.addTask {
                var blobs: [Data] = []
                for await frame in stream {
                    if case .deliver(_, _, let b) = frame { blobs.append(b) }
                    if blobs.count >= count { return blobs }
                }
                return blobs
            }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); return [] }
            defer { group.cancelAll() }
            return try await group.next()!
        }) ?? []
    }

    func close() { send.finish(); session.cancel() }
}

func welcome(_ f: ServerFrame) -> ServerMode? { if case .welcome(_, let m, _, _, _) = f { m } else { nil } }
func delivered(_ f: ServerFrame) -> Data? { if case .deliver(_, _, let b) = f { b } else { nil } }
func syncedComplete(_ f: ServerFrame) -> Bool? { if case .synced(_, _, true) = f { true } else { nil } }
func published(_ f: ServerFrame) -> Int? { if case .published(_, _, let r) = f { r } else { nil } }

@Suite(.serialized) struct RelayTests {
    let alice = Identity(name: "Alice")
    let bob = Identity(name: "Bob")

    func startServer(mode: ServerMode, accessKey: Data? = .random(32)) async throws -> (RelayServer, ServerInfo) {
        let server = try RelayServer(
            configuration: .init(host: "127.0.0.1", port: 0, mode: mode, accessKey: accessKey),
            privateKey: RelayServer.generatePrivateKey())
        let port = try await server.start()
        guard case .server(let info) = server.invite(host: "127.0.0.1", port: port) else { fatalError() }
        return (server, info)
    }

    @Test func relaysDirectMessageEndToEnd() async throws {
        let (server, info) = try await startServer(mode: .relay)
        let bobSide = try ConversationKeys.direct(me: bob, peer: alice.publicIdentity)
        let b = TestClient(info, tags: [bobSide.tag()])
        #expect(await b.next(syncedComplete) == true)

        let a = TestClient(info)
        #expect(await a.next(welcome) == .relay)
        let aliceSide = try ConversationKeys.direct(me: alice, peer: bob.publicIdentity)
        var aliceSessions = DirectSessions(), bobSessions = DirectSessions()
        a.send.yield(.publish(ref: 1, tag: aliceSide.tag(), blob: try aliceSide.seal(
            MessageBody(text: "moving out"), from: alice, sessions: &aliceSessions)))
        #expect(await a.next(published) == 1)  // one live recipient

        let got = try #require(await b.next(delivered))
        #expect(try bobSide.open(got, me: bob, sessions: &bobSessions).body.text == "moving out")
        a.close(); b.close()
        await server.stop()
    }

    @Test func relayModeReportsNobodyListening() async throws {
        let (server, info) = try await startServer(mode: .relay)
        let room = ConversationKeys.room(secret: .random(32))
        let a = TestClient(info)
        _ = await a.next(welcome)
        a.send.yield(.publish(ref: 1, tag: room.tag(), blob: try room.seal(MessageBody(text: "lost"), from: alice)))
        #expect(await a.next(published) == 0)

        let b = TestClient(info, tags: [room.tag()])
        #expect(await b.next(syncedComplete) == true)
        #expect(await b.next(timeout: 0.5, delivered) == nil)  // nothing retained
        a.close(); b.close()
        await server.stop()
    }

    /// Regression: Alice adds Bob and messages him at once. Bob only subscribes to their DM tag after
    /// accepting the request — by then his cursor is past the DM, which must still be delivered.
    @Test func messageSentBeforeSubscribingIsDelivered() async throws {
        let (server, info) = try await startServer(mode: .store)
        let inbox = ConversationKeys.inbox(of: bob.publicIdentity)
        let b = TestClient(info, tags: [inbox.tag()])
        #expect(await b.next(syncedComplete) == true)

        let a = TestClient(info)
        _ = await a.next(welcome)
        let aliceSide = try ConversationKeys.direct(me: alice, peer: bob.publicIdentity)
        a.send.yield(.publish(ref: 1, tag: inbox.tag(), blob: try inbox.seal(MessageBody(text: ""), from: alice)))
        var aliceSessions = DirectSessions(), bobSessions = DirectSessions()
        a.send.yield(.publish(ref: 2, tag: aliceSide.tag(), blob: try aliceSide.seal(
            MessageBody(text: "hi"), from: alice, sessions: &aliceSessions)))
        // Any later traffic on a tag Bob does follow moves his cursor past the DM.
        a.send.yield(.publish(ref: 3, tag: inbox.tag(), blob: try inbox.seal(MessageBody(text: ""), from: alice)))

        let intros = await b.collect(2)
        #expect(try inbox.open(try #require(intros.first), me: bob).sender == alice.publicIdentity)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(b.sync.cursor == 3)

        let bobSide = try ConversationKeys.direct(me: bob, peer: alice.publicIdentity)
        b.want([bobSide.tag()])
        let dm = try #require(await b.next(delivered))
        #expect(try bobSide.open(dm, me: bob, sessions: &bobSessions).body.text == "hi")
        a.close(); b.close()
        await server.stop()
    }

    @Test func largeBacklogArrivesInPages() async throws {
        let (server, info) = try await startServer(mode: .store)
        let room = ConversationKeys.room(secret: .random(32))
        let a = TestClient(info)
        _ = await a.next(welcome)
        let total = 1300
        for i in 1...total {
            a.send.yield(.publish(ref: UInt32(i), tag: room.tag(), blob: try room.seal(MessageBody(text: "\(i)"), from: alice)))
        }
        #expect(await a.next { if case .published(UInt32(total), _, _) = $0 { true } else { nil } } == true)

        let b = TestClient(info, tags: room.tags(covering: 86_400))
        let blobs = await b.collect(total, timeout: 15)
        #expect(blobs.count == total)
        let texts = Set(try blobs.map { try room.open($0, me: bob).body.text })
        #expect(texts.count == total)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!b.sync.isCatchingUp && b.sync.cursor == UInt64(total))
        a.close(); b.close()
        await server.stop()
    }

    /// Regression: a server restarted without persistence starts numbering again; a client holding an old
    /// high cursor must not skip the new messages.
    @Test func cursorResetsWhenServerLosesItsStore() async throws {
        let key = RelayServer.generatePrivateKey()
        let room = ConversationKeys.room(secret: .random(32))
        let stale = SyncState(instance: Data.random(16), cursor: 10_000)

        let server = try RelayServer(configuration: .init(host: "127.0.0.1", port: 0, mode: .store), privateKey: key)
        let port = try await server.start()
        guard case .server(let info) = server.invite(host: "127.0.0.1", port: port) else { fatalError() }
        let a = TestClient(info)
        _ = await a.next(welcome)
        a.send.yield(.publish(ref: 1, tag: room.tag(), blob: try room.seal(MessageBody(text: "after restart"), from: alice)))
        _ = await a.next(published)

        let b = TestClient(info, tags: [room.tag()], sync: stale)
        let got = try #require(await b.next(delivered))
        #expect(try room.open(got, me: bob).body.text == "after restart")
        a.close(); b.close()
        await server.stop()
    }

    @Test func listenerRestartKeepsStore() async throws {
        let (server, info) = try await startServer(mode: .store)
        let room = ConversationKeys.room(secret: .random(32))
        let a = TestClient(info)
        _ = await a.next(welcome)
        a.send.yield(.publish(ref: 1, tag: room.tag(), blob: try room.seal(MessageBody(text: "kept"), from: alice)))
        _ = await a.next(published)

        try await server.start()  // rebind, as the app does when returning from the background
        #expect(await a.next(welcome) == nil)  // old connections were closed

        let b = TestClient(info, tags: [room.tag()])
        #expect(try room.open(try #require(await b.next(delivered)), me: bob).body.text == "kept")
        a.close(); b.close()
        await server.stop()
    }

    @Test func wrongAccessKeyGetsSilence() async throws {
        let (server, info) = try await startServer(mode: .relay)
        var bad = info
        bad.accessKey = .random(32)
        let c = TestClient(bad)
        #expect(await c.next(welcome) == nil)
        await #expect(throws: (any Error).self) { try await c.session.value }
        c.close()
        await server.stop()
    }
}

/// Exercises an externally running server, e.g. the iOS app hosting in the Simulator:
///   UMBRA_PROBE_INVITE='umbra://server?...' swift test --filter ExternalServerProbe
@Suite struct ExternalServerProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UMBRA_PROBE_INVITE"] != nil))
    func roomAndDirectMessagesThroughExternalServer() async throws {
        guard case .server(let info) = try Invite(url: ProcessInfo.processInfo.environment["UMBRA_PROBE_INVITE"]!) else {
            Issue.record("not a server invite"); return
        }
        let alice = Identity(name: "Alice"), bob = Identity(name: "Bob")
        let room = ConversationKeys.room(secret: .random(32))
        let bobDM = try ConversationKeys.direct(me: bob, peer: alice.publicIdentity)

        let b = TestClient(info, tags: [room.tag(), bobDM.tag()])
        #expect(await b.next(syncedComplete) == true)
        let a = TestClient(info)
        #expect(await a.next(welcome) != nil)

        a.send.yield(.publish(ref: 1, tag: room.tag(), blob: try room.seal(MessageBody(text: "room via iOS host"), from: alice)))
        let aliceDM = try ConversationKeys.direct(me: alice, peer: bob.publicIdentity)
        a.send.yield(.publish(ref: 2, tag: aliceDM.tag(), blob: try aliceDM.seal(MessageBody(text: "dm via iOS host"), from: alice)))

        let blobs = await b.collect(2)
        #expect(blobs.count == 2)
        let texts = Set(blobs.compactMap { (try? room.open($0, me: bob)) ?? (try? bobDM.open($0, me: bob)) }.map(\.body.text))
        #expect(texts == ["room via iOS host", "dm via iOS host"])
        a.close(); b.close()
    }
}

@Suite struct PublicAddressTests {
    @Test func classifiesRanges() {
        for address in ["8.8.8.8", "1.1.1.1", "95.216.10.20", "172.32.0.1", "100.128.0.1"] {
            #expect(PublicAddress.isPublic(address), "\(address)")
        }
        for address in ["10.1.2.3", "192.168.50.147", "172.16.0.1", "172.31.255.255", "100.64.0.1", "127.0.0.1",
                        "169.254.1.1", "203.0.113.10", "224.0.0.1", "0.0.0.0", "not.an.ip", "1.2.3"] {
            #expect(!PublicAddress.isPublic(address), "\(address)")
        }
    }

    /// A Binding success response as RFC 5769 (test vector 2.2) builds it: 192.0.2.1 port 32853.
    @Test func parsesStunResponse() {
        let transaction = Data([0xB7, 0xE7, 0xA7, 0x01, 0xBC, 0x34, 0xD6, 0x86, 0xFA, 0x87, 0xDF, 0xAE])
        var response = Data([0x01, 0x01, 0x00, 0x0C, 0x21, 0x12, 0xA4, 0x42]) + transaction
        response += Data([0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xA1, 0x47, 0xE1, 0x12, 0xA6, 0x43])
        #expect(PublicAddress.parseBindingResponse(response, transaction: transaction) == "192.0.2.1")
        #expect(PublicAddress.parseBindingResponse(response, transaction: Data(count: 12)) == nil)
        #expect(PublicAddress.parseBindingResponse(response.prefix(20), transaction: transaction) == nil)
    }
}
