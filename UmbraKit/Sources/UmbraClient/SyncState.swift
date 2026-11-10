import Foundation
import UmbraCore

/// Client-side bookkeeping for one server: which tags are subscribed, the store cursor, and paged
/// catch-up. A pure state machine — callers feed it server frames and send the frames it returns.
///
/// Cursor rule: the persisted cursor only advances when no catch-up is in flight, so a disconnect
/// mid-catch-up never skips stored messages (re-delivery is harmless; receivers dedupe by message id).
public struct SyncState: Sendable {
    public private(set) var instance: Data?
    public private(set) var cursor: UInt64
    public private(set) var isStore = false
    private var subscribed: Set<Tag> = []
    private var pending: [UInt32: [Tag]] = [:]
    private var nextID: UInt32 = 1
    private var online = false

    public init(instance: Data? = nil, cursor: UInt64 = 0) {
        self.instance = instance
        self.cursor = cursor
    }

    public var isCatchingUp: Bool { !pending.isEmpty }

    /// After `welcome`: subscribe to everything, replaying what was stored since the last visit.
    public mutating func connected(mode: ServerMode, instance: Data, desired: Set<Tag>) -> [ClientFrame] {
        isStore = mode == .store
        if instance != self.instance {
            // New server, or it lost its store and restarted numbering: start from the beginning.
            self.instance = instance
            cursor = 0
        }
        subscribed = []
        pending = [:]
        online = true
        return update(desired: desired, since: cursor)
    }

    public mutating func disconnected() {
        online = false
        subscribed = []
        pending = [:]
    }

    /// The set of wanted tags changed (new contact/room, daily rotation). Newly added tags are fetched
    /// from the beginning of the store: their conversation may already have messages waiting.
    public mutating func update(desired: Set<Tag>) -> [ClientFrame] {
        update(desired: desired, since: 0)
    }

    private mutating func update(desired: Set<Tag>, since: UInt64) -> [ClientFrame] {
        guard online else { return [] }
        var frames: [ClientFrame] = []
        let removed = subscribed.subtracting(desired)
        if !removed.isEmpty { frames.append(.unsubscribe(tags: Array(removed))) }
        let added = desired.subtracting(subscribed)
        if !added.isEmpty { frames.append(request(Array(added), since: isStore ? since : nil)) }
        subscribed = desired
        return frames
    }

    /// Feed every server frame. Returns follow-up frames to send (next catch-up page).
    public mutating func received(_ frame: ServerFrame) -> [ClientFrame] {
        switch frame {
        case .deliver(let seq, _, _), .published(_, let seq, _):
            if pending.isEmpty { cursor = max(cursor, seq) }
        case .synced(let id, let through, let complete):
            guard let tags = pending.removeValue(forKey: id) else { return [] }
            if !complete {
                let still = tags.filter(subscribed.contains)
                if !still.isEmpty { return [request(still, since: through)] }
            }
            // Everything up to `through` on every subscribed tag has now been delivered in order.
            if pending.isEmpty { cursor = max(cursor, through) }
        default:
            break
        }
        return []
    }

    private mutating func request(_ tags: [Tag], since: UInt64?) -> ClientFrame {
        let id = nextID
        nextID &+= 1
        pending[id] = tags
        return .subscribe(id: id, tags: tags, since: since)
    }
}
