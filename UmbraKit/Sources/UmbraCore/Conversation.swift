import Foundation

/// Plaintext content of a chat message, signed by its author inside the encryption.
public struct MessageBody: Codable, Hashable, Sendable {
    public let id: UUID
    public let sentAt: Date
    public let text: String
    /// Delivery receipt: ids of the peer's messages we received (direct chats only). A receipt is not
    /// shown as a message; sending one also moves the ratchet forward so the peer gets forward secrecy.
    public let acks: [UUID]?

    public init(id: UUID = UUID(), sentAt: Date = Date(), text: String, acks: [UUID]? = nil) {
        self.id = id
        self.sentAt = sentAt
        self.text = text
        self.acks = acks
    }

    public var isReceipt: Bool { acks != nil }
}

public struct ReceivedMessage: Sendable, Equatable {
    public let sender: PublicIdentity
    public let body: MessageBody
}

/// End-to-end keys for one conversation (a direct chat or a room). Servers never see these.
public struct ConversationKeys: Sendable {
    public enum Kind: Sendable {
        case direct(peer: PublicIdentity)
        case room(secret: Data)
        /// A person's public mailbox for contact requests. Anyone with their public identity can write
        /// to it (sealed so only the owner can read), only the owner can read it.
        case inbox(owner: PublicIdentity)
    }

    public let kind: Kind
    /// Root secret: pairwise DH secret for direct chats, the shared room secret for rooms.
    let root: SymmetricKey
    /// Bound into every signature so a message cannot be replayed into another conversation.
    public let conversationID: Data

    public static func direct(me: Identity, peer: PublicIdentity) throws -> ConversationKeys {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.kxKey)
        let dh = try me.agreement.sharedSecretFromKeyAgreement(with: peerKey).data
        let mine = me.publicIdentity.signKey
        let pair = mine.lexicographicallyPrecedes(peer.signKey) ? mine + peer.signKey : peer.signKey + mine
        let root = KDF.derive(dh, salt: pair, info: "umbra/dm/root")
        let id = Data(SHA256.hash(data: Data("umbra/dm/id".utf8) + pair)).prefix(16)
        return ConversationKeys(kind: .direct(peer: peer), root: root, conversationID: id)
    }

    public static func room(secret: Data) -> ConversationKeys {
        let root = KDF.derive(secret, salt: Data(), info: "umbra/room/root")
        let id = Data(SHA256.hash(data: Data("umbra/room/id".utf8) + secret)).prefix(16)
        return ConversationKeys(kind: .room(secret: secret), root: root, conversationID: id)
    }

    public static func inbox(of owner: PublicIdentity) -> ConversationKeys {
        let root = KDF.derive(owner.signKey + owner.kxKey, salt: Data(), info: "umbra/inbox/root")
        let id = Data(SHA256.hash(data: Data("umbra/inbox/id".utf8) + owner.signKey)).prefix(16)
        return ConversationKeys(kind: .inbox(owner: owner), root: root, conversationID: id)
    }

    public static func newRoomSecret() -> Data { .random(32) }

    // MARK: Routing tags

    public static let tagPeriod: TimeInterval = 86_400

    public static func epoch(of date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970) / tagPeriod)
    }

    public func tag(epoch: UInt64) -> Tag {
        var msg = Data("umbra/tag".utf8)
        msg.appendBE(epoch)
        return Tag(KDF.hmac(root, msg))
    }

    public func tag(at date: Date = Date()) -> Tag { tag(epoch: Self.epoch(of: date)) }

    /// Tags to listen on: every period that may still hold stored messages, plus tomorrow for clock skew.
    public func tags(covering retention: TimeInterval, now: Date = Date()) -> [Tag] {
        let current = Self.epoch(of: now)
        let back = UInt64(max(0, retention) / Self.tagPeriod) + 1
        let first = current >= back ? current - back : 0
        return (first...(current + 1)).map(tag(epoch:))
    }

    // MARK: Message sealing

    private static let inboxBlob: UInt8 = 1
    private static let roomBlob: UInt8 = 2

    /// Seals a room message or contact request. Direct messages go through the ratchet instead
    /// (`seal(_:from:sessions:)`).
    public func seal(_ body: MessageBody, from me: Identity) throws -> Data {
        try seal(envelope: try envelope(body, from: me))
    }

    func envelope(_ body: MessageBody, from me: Identity) throws -> SignedEnvelope {
        let bodyData = try WireCodec.encode(body)
        let signature = try me.signing.signature(for: signedBytes(bodyData, sender: me.publicIdentity))
        return SignedEnvelope(sender: me.publicIdentity, body: bodyData, signature: signature)
    }

    func seal(envelope inner: SignedEnvelope) throws -> Data {
        let plaintext = Padding.pad(try WireCodec.encode(inner))

        switch kind {
        case .direct:
            throw UmbraError.notForUs
        case .inbox(let peer):
            // Fresh ephemeral per request: recovering one key reveals nothing about others.
            let e = Curve25519.KeyAgreement.PrivateKey()
            let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.kxKey)
            let dh = try e.sharedSecretFromKeyAgreement(with: peerKey).data
            let epub = e.publicKey.rawRepresentation
            let key = KDF.derive(dh + root.data, salt: epub, info: "umbra/inbox/msg")
            var blob = Data([Self.inboxBlob])
            blob.append(epub)
            blob.append(try ChaChaPoly.seal(plaintext, using: key).combined)
            return blob
        case .room:
            let salt = Data.random(16)
            let key = KDF.derive(root.data, salt: salt, info: "umbra/room/msg")
            var blob = Data([Self.roomBlob])
            blob.append(salt)
            blob.append(try ChaChaPoly.seal(plaintext, using: key).combined)
            return blob
        }
    }

    /// Decrypts and authenticates a room message or contact request. Throws if it is not for this
    /// conversation or was tampered with.
    public func open(_ blob: Data, me: Identity) throws -> ReceivedMessage {
        guard let type = blob.first else { throw UmbraError.malformed }
        let rest = blob.dropFirst()
        let plaintext: Data
        switch (kind, type) {
        case (.inbox, Self.inboxBlob):
            guard rest.count > 32 else { throw UmbraError.malformed }
            let epubData = Data(rest.prefix(32))
            let epub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epubData)
            // Messages we sent ourselves (e.g. replayed from a store) cannot be opened, which is fine:
            // the sender keeps its own copy locally.
            let dh = try me.agreement.sharedSecretFromKeyAgreement(with: epub).data
            let key = KDF.derive(dh + root.data, salt: epubData, info: "umbra/inbox/msg")
            plaintext = try Self.decrypt(Data(rest.dropFirst(32)), key: key)
        case (.room, Self.roomBlob):
            guard rest.count > 16 else { throw UmbraError.malformed }
            let key = KDF.derive(root.data, salt: Data(rest.prefix(16)), info: "umbra/room/msg")
            plaintext = try Self.decrypt(Data(rest.dropFirst(16)), key: key)
        default:
            throw UmbraError.notForUs
        }
        return try verified(plaintext)
    }

    /// Checks the author's signature on a decrypted message; in a direct chat the author must be the peer.
    func verified(_ plaintext: Data) throws -> ReceivedMessage {
        let inner = try WireCodec.decode(SignedEnvelope.self, from: try Padding.unpad(plaintext))
        guard inner.sender.verify(inner.signature, for: signedBytes(inner.body, sender: inner.sender)) else {
            throw UmbraError.badSignature
        }
        if case .direct(let peer) = kind {
            // Only the peer could have derived the key, but also insist the signer is that peer.
            guard inner.sender.signKey == peer.signKey, inner.sender.kxKey == peer.kxKey else {
                throw UmbraError.badSignature
            }
        }
        return ReceivedMessage(sender: inner.sender, body: try WireCodec.decode(MessageBody.self, from: inner.body))
    }

    /// The signature covers the conversation, the sender's complete public identity (both keys and name)
    /// and the body. Without the identity, a room member could re-wrap someone else's signed message with
    /// their own agreement key or name, and anyone adding that "sender" as a contact would encrypt to them.
    private func signedBytes(_ body: Data, sender: PublicIdentity) -> Data {
        var out = Data("umbra/msg/v2".utf8) + conversationID + sender.signKey + sender.kxKey
        let name = Data(sender.name.utf8)
        out.appendBE(UInt32(name.count))
        out.append(name)
        out.append(body)
        return out
    }

    static func decrypt(_ combined: Data, key: SymmetricKey, ad: Data = Data()) throws -> Data {
        do { return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: key, authenticating: ad) } catch {
            throw UmbraError.decryptionFailed
        }
    }
}

struct SignedEnvelope: Codable {
    let sender: PublicIdentity
    let body: Data
    let signature: Data
}
