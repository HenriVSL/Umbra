import Foundation

/// Opaque 16-byte routing label. The server routes and stores by tag only; tags are derived from
/// conversation secrets and rotate daily, so the server cannot tell who talks to whom.
public struct Tag: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: Data
    public init(_ raw: Data) { self.raw = raw.prefix(16) }
    public var description: String { raw.prefix(4).hex }
}

public enum ServerMode: String, Codable, Sendable, CaseIterable {
    /// Forward to connected subscribers only; nothing is ever written anywhere.
    case relay
    /// Also keep encrypted blobs (in RAM, optionally an encrypted snapshot) until their TTL expires.
    case store
}

/// Frames sent by clients, carried inside the secure channel.
public enum ClientFrame: Codable, Sendable, Equatable {
    /// Adds tags to this connection's subscriptions. With `since`, stored blobs on these tags newer than
    /// that sequence number are replayed, at most one page at a time; the server answers with `synced`.
    case subscribe(id: UInt32, tags: [Tag], since: UInt64?)
    case unsubscribe(tags: [Tag])
    case publish(ref: UInt32, tag: Tag, blob: Data)
    case ping
}

/// Frames sent by servers, carried inside the secure channel.
public enum ServerFrame: Codable, Sendable, Equatable {
    /// `instance` changes whenever the server loses its store (restart without persistence):
    /// clients must then forget their cursor, since sequence numbers start over.
    case welcome(name: String, mode: ServerMode, retentionSeconds: Int, instance: Data, cursor: UInt64)
    case deliver(seq: UInt64, tag: Tag, blob: Data)
    /// `recipients` = connections the blob was forwarded to live (0 in relay mode means nobody got it).
    case published(ref: UInt32, seq: UInt64, recipients: Int)
    /// Answers `subscribe`. Everything stored up to `through` on those tags has been delivered.
    /// When `complete` is false, more backlog remains: subscribe again with `since: through`.
    case synced(id: UInt32, through: UInt64, complete: Bool)
    case pong
    case error(String)
}

public enum WireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw UmbraError.malformed }
    }
}
