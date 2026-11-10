import Foundation
import UmbraCore

/// Routing state shared by all connections. Knows only opaque tags and ciphertext blobs.
actor RelayHub {
    struct Stored: Codable {
        let seq: UInt64
        let tag: Tag
        let blob: Data
        let expires: Date
    }

    typealias Outbox = AsyncStream<ServerFrame>.Continuation

    /// Outbox depth per connection. Must exceed `pageSize` plus live traffic during a page.
    static let outboxDepth = 2048
    static let pageSize = 512
    static let maxTagsPerConnection = 8192

    let mode: ServerMode
    let retention: TimeInterval
    let maxStoredBytes: Int
    let maxConnections: Int

    /// Identifies this store's sequence space; regenerated when stored data is lost.
    private(set) var instance = Data.random(16)
    private(set) var cursor: UInt64 = 0
    private var outboxes: [UUID: Outbox] = [:]
    private var subscriptions: [UUID: Set<Tag>] = [:]
    private var subscribers: [Tag: Set<UUID>] = [:]
    private var stored: [Tag: [Stored]] = [:]
    private var storedBytes = 0
    private(set) var dirty = false
    /// Bumped whenever the listener stops, so a connection still in its handshake cannot join afterwards.
    private(set) var epoch = 0

    init(mode: ServerMode, retention: TimeInterval, maxStoredBytes: Int, maxConnections: Int) {
        self.mode = mode
        self.retention = retention
        self.maxStoredBytes = maxStoredBytes
        self.maxConnections = maxConnections
    }

    var connectionCount: Int { outboxes.count }

    /// Registers a connection. Returns false when the server is full or the listener has since stopped.
    func connect(_ id: UUID, outbox: Outbox, epoch: Int) -> Bool {
        guard epoch == self.epoch, outboxes.count < maxConnections else { return false }
        outboxes[id] = outbox
        return true
    }

    func disconnect(_ id: UUID) {
        outboxes.removeValue(forKey: id)?.finish()
        for tag in subscriptions.removeValue(forKey: id) ?? [] {
            subscribers[tag]?.remove(id)
            if subscribers[tag]?.isEmpty == true { subscribers[tag] = nil }
        }
    }

    /// Queues a frame. A connection that cannot keep up is closed rather than silently skipping frames,
    /// so a client never advances its cursor past something it did not receive.
    @discardableResult
    func send(_ frame: ServerFrame, to id: UUID) -> Bool {
        guard let outbox = outboxes[id] else { return false }
        if case .dropped = outbox.yield(frame) {
            disconnect(id)
            return false
        }
        return true
    }

    func subscribe(_ id: UUID, request: UInt32, tags: [Tag], since: UInt64?) {
        guard outboxes[id] != nil else { return }
        var current = subscriptions[id] ?? []
        guard current.count + tags.count <= Self.maxTagsPerConnection || tags.allSatisfy(current.contains) else {
            send(.error("too many subscriptions"), to: id)
            return
        }
        for tag in tags {
            current.insert(tag)
            subscribers[tag, default: []].insert(id)
        }
        subscriptions[id] = current

        guard let since, mode == .store else {
            send(.synced(id: request, through: cursor, complete: true), to: id)
            return
        }
        let now = Date()
        let backlog = Set(tags).flatMap { stored[$0] ?? [] }
            .filter { $0.seq > since && $0.expires > now }
            .sorted { $0.seq < $1.seq }
        let page = backlog.prefix(Self.pageSize)
        for item in page {
            guard send(.deliver(seq: item.seq, tag: item.tag, blob: item.blob), to: id) else { return }
        }
        let complete = backlog.count <= Self.pageSize
        send(.synced(id: request, through: complete ? cursor : page.last!.seq, complete: complete), to: id)
    }

    func unsubscribe(_ id: UUID, tags: [Tag]) {
        for tag in tags {
            subscriptions[id]?.remove(tag)
            subscribers[tag]?.remove(id)
            if subscribers[tag]?.isEmpty == true { subscribers[tag] = nil }
        }
    }

    func publish(from id: UUID, ref: UInt32, tag: Tag, blob: Data) {
        cursor += 1
        let seq = cursor
        if mode == .store {
            stored[tag, default: []].append(Stored(seq: seq, tag: tag, blob: blob, expires: Date().addingTimeInterval(retention)))
            storedBytes += blob.count
            dirty = true
            while storedBytes > maxStoredBytes, evictOldest() {}
        }
        var recipients = 0
        for subscriber in subscribers[tag] ?? [] where subscriber != id {
            if send(.deliver(seq: seq, tag: tag, blob: blob), to: subscriber) { recipients += 1 }
        }
        send(.published(ref: ref, seq: seq, recipients: recipients), to: id)
    }

    func purgeExpired(now: Date = Date()) {
        guard mode == .store else { return }
        for (tag, list) in stored {
            let kept = list.filter { $0.expires > now }
            guard kept.count != list.count else { continue }
            storedBytes -= list.reduce(0) { $0 + $1.blob.count } - kept.reduce(0) { $0 + $1.blob.count }
            stored[tag] = kept.isEmpty ? nil : kept
            dirty = true
        }
    }

    private func evictOldest() -> Bool {
        guard let (tag, list) = stored.min(by: { ($0.value.first?.seq ?? .max) < ($1.value.first?.seq ?? .max) }),
              let oldest = list.first
        else { return false }
        storedBytes -= oldest.blob.count
        stored[tag] = list.count == 1 ? nil : Array(list.dropFirst())
        return true
    }

    // MARK: Snapshot (store mode only)

    struct Snapshot: Codable {
        let instance: Data
        let cursor: UInt64
        let items: [Stored]
    }

    func snapshot() -> Snapshot {
        dirty = false
        return Snapshot(instance: instance, cursor: cursor, items: stored.values.flatMap { $0 }.sorted { $0.seq < $1.seq })
    }

    func restore(_ snapshot: Snapshot) {
        instance = snapshot.instance
        cursor = max(cursor, snapshot.cursor)
        let now = Date()
        for item in snapshot.items where item.expires > now {
            stored[item.tag, default: []].append(item)
            storedBytes += item.blob.count
        }
    }

    func disconnectAll() {
        epoch += 1
        for id in Array(outboxes.keys) { disconnect(id) }
    }
}
