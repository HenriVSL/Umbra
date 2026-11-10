import Foundation
import UmbraCore

struct Contact: Codable, Identifiable, Hashable {
    var identity: PublicIdentity
    /// Set only when the contact's code was scanned with the camera, or the fingerprint compared in person.
    var verified: Bool
    var id: String { identity.id }
}

struct Room: Codable, Identifiable, Hashable {
    var name: String
    var secret: Data
    var id: String { ConversationKeys.room(secret: secret).conversationID.hex }
    var invite: Invite { .room(name: name, secret: secret) }
}

enum ConversationRef: Codable, Hashable {
    case direct(contactID: String)
    case room(roomID: String)
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        /// Not yet accepted by any server.
        case pending
        /// Accepted by a server (stored, or forwarded to at least one listener).
        case sent
        /// Relay-only servers accepted it but nobody was listening: it was not delivered.
        case unheard
        /// The recipient's device confirmed it (direct chats).
        case delivered
        case received
    }

    var id: UUID
    var conversation: ConversationRef
    var senderID: String
    var senderName: String
    /// Full public identity of the author, so room members can be added as contacts.
    var sender: PublicIdentity?
    var text: String
    var sentAt: Date
    var status: Status

    var isOutgoing: Bool { status != .received }
}

struct ServerEntry: Codable, Identifiable, Hashable {
    var info: ServerInfo
    var enabled = true
    /// Store-mode resume point (see `SyncState`), valid only for the server instance it came from.
    var instance: Data?
    var cursor: UInt64 = 0
    /// Points at this device's own hosted server.
    var isLocalHost = false
    var id: String { info.id }
}

struct HostSettings: Codable, Hashable {
    var privateKey: Data
    var accessKey: Data?
    var name: String
    var port: Int = 7443
    var mode: ServerMode = .store
    var retentionHours: Int = 72
    /// Memory cap for stored messages — matters on a phone.
    var maxStoreMB: Int = 64
    var autoStart = false
    /// Announce on the local network so clients follow this host when its IP address changes.
    var announce = true
}

/// A contact request received in our inbox, awaiting accept/ignore.
struct ContactRequest: Codable, Identifiable, Hashable {
    var identity: PublicIdentity
    var receivedAt: Date
    var id: String { identity.id }
}

/// Everything persisted, sealed as one blob in the vault.
struct VaultState: Codable {
    var name: String
    var signingKey: Data
    var agreementKey: Data
    var contacts: [Contact] = []
    var requests: [ContactRequest] = []
    var rooms: [Room] = []
    var servers: [ServerEntry] = []
    var messages: [ConversationRef: [ChatMessage]] = [:]
    /// Contacts whose inbox has not yet received our contact request (no server was online when added).
    var pendingIntros: [String] = []
    var host: HostSettings
    /// Local auto-delete for messages; nil keeps them until deleted.
    var messageLifetimeHours: Int?
    /// Double Ratchet state per contact id.
    var sessions: [String: DirectSessions] = [:]
    /// Outgoing messages sealed but not yet accepted by a server. Each is sealed exactly once, so every
    /// server and every retry carries the same ciphertext (re-sealing would burn ratchet keys).
    var outbox: [UUID: Data] = [:]

    init(name: String, signingKey: Data, agreementKey: Data, host: HostSettings) {
        self.name = name
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        self.host = host
    }

    /// Fields added later decode to their defaults, so an older vault still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        signingKey = try c.decode(Data.self, forKey: .signingKey)
        agreementKey = try c.decode(Data.self, forKey: .agreementKey)
        host = try c.decode(HostSettings.self, forKey: .host)
        contacts = try c.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
        requests = try c.decodeIfPresent([ContactRequest].self, forKey: .requests) ?? []
        rooms = try c.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        servers = try c.decodeIfPresent([ServerEntry].self, forKey: .servers) ?? []
        messages = try c.decodeIfPresent([ConversationRef: [ChatMessage]].self, forKey: .messages) ?? [:]
        pendingIntros = try c.decodeIfPresent([String].self, forKey: .pendingIntros) ?? []
        messageLifetimeHours = try c.decodeIfPresent(Int.self, forKey: .messageLifetimeHours)
        sessions = try c.decodeIfPresent([String: DirectSessions].self, forKey: .sessions) ?? [:]
        outbox = try c.decodeIfPresent([UUID: Data].self, forKey: .outbox) ?? [:]
    }
}
