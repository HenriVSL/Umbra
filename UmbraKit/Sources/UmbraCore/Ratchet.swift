import Foundation

/// Double Ratchet state for one contact (the Signal design). Every message has its own key, deleted
/// once used, and each change of speaker mixes in fresh Diffie-Hellman keys. So a phone captured later
/// cannot read messages it already processed, and a copied state stops working after one round trip.
///
/// There is no prekey server: a session starts from the two agreement keys exchanged in the QR codes.
/// Until the peer answers (a reply or the automatic delivery receipt), messages in that first chain
/// still depend on the peer's long-term key.
///
/// Either side may start a session, even both at once. Each side sends on the session it last received
/// on, so the two converge. Mutating calls are all-or-nothing: on any error the state is unchanged.
public struct DirectSessions: Codable, Sendable, Equatable {
    static let maxSessions = 4
    static let maxRetired = 32
    /// Largest gap of missing messages accepted in one chain.
    static let maxSkip: UInt32 = 1000
    static let maxSkippedKeys = 2000
    /// Keys of messages that never arrived are kept only this long (beyond any server's retention).
    static let skippedKeyLifetime: TimeInterval = 14 * 86_400

    /// Most recently active first; the first one is used for sending.
    var sessions: [RatchetSession] = []
    /// Evicted sessions, so a replayed opening message cannot resurrect one.
    var retired: [Data] = []

    public init() {}

    /// Drops keys kept for messages that never arrived once they are too old to matter.
    public mutating func expireSkippedKeys(now: Date = Date()) {
        for i in sessions.indices { sessions[i].skipped.removeAll { $0.expires <= now } }
    }

    mutating func promote(_ session: RatchetSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        while sessions.count > Self.maxSessions { retired.append(sessions.removeLast().id) }
        if retired.count > Self.maxRetired { retired.removeFirst(retired.count - Self.maxRetired) }
    }
}

struct RatchetSession: Codable, Sendable, Equatable {
    struct Skipped: Codable, Sendable, Equatable {
        let ratchetKey: Data
        let number: UInt32
        let messageKey: Data
        let expires: Date
    }

    let id: Data
    var rootKey: Data
    /// Our current ratchet private key.
    var ourKey: Data
    /// Their current ratchet public key (their long-term agreement key until they first reply).
    var theirKey: Data?
    var sendChain: Data?
    var receiveChain: Data?
    var sent: UInt32 = 0
    var received: UInt32 = 0
    /// Length of our previous sending chain, so the peer can keep keys for stragglers.
    var previous: UInt32 = 0
    var skipped: [Skipped] = []

    /// We start: our first chain is keyed from a fresh key and the peer's long-term key.
    static func initiate(id: Data, rootKey: Data, peerKey: Data) throws -> RatchetSession {
        let ours = Curve25519.KeyAgreement.PrivateKey()
        let (root, chain) = try kdfRoot(rootKey, dh(ours, peerKey))
        return RatchetSession(id: id, rootKey: root, ourKey: ours.rawRepresentation, theirKey: peerKey, sendChain: chain)
    }

    /// The peer started: our long-term key plays the first ratchet key, and is replaced on the first step.
    static func respond(id: Data, rootKey: Data, ourKey: Data) -> RatchetSession {
        RatchetSession(id: id, rootKey: rootKey, ourKey: ourKey)
    }

    mutating func nextSendingKey() throws -> (SymmetricKey, RatchetHeader) {
        guard let chain = sendChain else { throw UmbraError.decryptionFailed }
        let ours = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ourKey)
        let (next, key) = Self.chainStep(chain)
        let header = RatchetHeader(session: id, ratchetKey: ours.publicKey.rawRepresentation, previous: previous, number: sent)
        sendChain = next
        sent += 1
        return (SymmetricKey(data: key), header)
    }

    mutating func receivingKey(for header: RatchetHeader, now: Date) throws -> SymmetricKey {
        if let i = skipped.firstIndex(where: { $0.ratchetKey == header.ratchetKey && $0.number == header.number }) {
            return SymmetricKey(data: skipped.remove(at: i).messageKey)
        }
        if header.ratchetKey != theirKey {
            try skip(until: header.previous, now: now)
            try step(theirs: header.ratchetKey)
        }
        try skip(until: header.number, now: now)
        // An older number that is not among the skipped keys was already read (or forged): the chain
        // yields a different key and decryption fails.
        guard let chain = receiveChain else { throw UmbraError.decryptionFailed }
        let (next, key) = Self.chainStep(chain)
        receiveChain = next
        received += 1
        return SymmetricKey(data: key)
    }

    /// Keeps keys for messages of the current receiving chain that have not arrived yet.
    private mutating func skip(until number: UInt32, now: Date) throws {
        guard var chain = receiveChain, let theirs = theirKey, number > received else { return }
        guard number - received <= DirectSessions.maxSkip else { throw UmbraError.malformed }
        while received < number {
            let (next, key) = Self.chainStep(chain)
            skipped.append(Skipped(
                ratchetKey: theirs, number: received, messageKey: key,
                expires: now.addingTimeInterval(DirectSessions.skippedKeyLifetime)))
            chain = next
            received += 1
        }
        receiveChain = chain
        if skipped.count > DirectSessions.maxSkippedKeys { skipped.removeFirst(skipped.count - DirectSessions.maxSkippedKeys) }
    }

    /// The peer has a new ratchet key: derive their new sending chain, then our own from a fresh key.
    private mutating func step(theirs: Data) throws {
        previous = sent
        sent = 0
        received = 0
        theirKey = theirs
        let current = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ourKey)
        (rootKey, receiveChain) = try Self.kdfRoot(rootKey, Self.dh(current, theirs))
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        ourKey = fresh.rawRepresentation
        (rootKey, sendChain) = try Self.kdfRoot(rootKey, Self.dh(fresh, theirs))
    }

    private static func dh(_ ours: Curve25519.KeyAgreement.PrivateKey, _ theirs: Data) throws -> Data {
        try ours.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs)).data
    }

    private static func kdfRoot(_ rootKey: Data, _ dh: Data) throws -> (Data, Data) {
        let out = KDF.derive(dh, salt: rootKey, info: "umbra/dm/ratchet", count: 64).data
        return (out.prefix(32), out.suffix(32))
    }

    /// (next chain key, message key)
    private static func chainStep(_ chain: Data) -> (Data, Data) {
        let key = SymmetricKey(data: chain)
        return (KDF.hmac(key, Data([2])), KDF.hmac(key, Data([1])))
    }
}

struct RatchetHeader: Equatable {
    static let sessionIDLength = 8
    static let length = sessionIDLength + 32 + 4 + 4
    /// Nonce + header + tag.
    static let sealedLength = 12 + length + 16

    let session: Data
    let ratchetKey: Data
    let previous: UInt32
    let number: UInt32

    var encoded: Data {
        var out = session + ratchetKey
        out.appendBE(previous)
        out.appendBE(number)
        return out
    }

    init(session: Data, ratchetKey: Data, previous: UInt32, number: UInt32) {
        self.session = session
        self.ratchetKey = ratchetKey
        self.previous = previous
        self.number = number
    }

    init(_ data: Data) throws {
        let data = Data(data)
        guard data.count == Self.length,
              let previous = data.readBE(UInt32.self, at: 40), let number = data.readBE(UInt32.self, at: 44)
        else { throw UmbraError.malformed }
        session = data.prefix(Self.sessionIDLength)
        ratchetKey = data.subdata(in: 8..<40)
        self.previous = previous
        self.number = number
    }
}

extension ConversationKeys {
    static let ratchetBlob: UInt8 = 3

    /// Encrypts a direct message, advancing the ratchet. Save `sessions` before the blob leaves the
    /// device: reusing a ratchet state that already sent breaks the session for the peer.
    public func seal(_ body: MessageBody, from me: Identity, sessions: inout DirectSessions) throws -> Data {
        guard case .direct(let peer) = kind else { throw UmbraError.notForUs }
        let plaintext = Padding.pad(try WireCodec.encode(try envelope(body, from: me)))

        var session: RatchetSession
        if let current = sessions.sessions.first {
            session = current
        } else {
            let id = Data.random(RatchetHeader.sessionIDLength)
            session = try .initiate(id: id, rootKey: sessionRoot(id), peerKey: peer.kxKey)
        }
        let (key, header) = try session.nextSendingKey()

        var blob = Data([Self.ratchetBlob])
        blob.append(try ChaChaPoly.seal(header.encoded, using: headerKey(from: me.publicIdentity), authenticating: headerAD).combined)
        blob.append(try ChaChaPoly.seal(plaintext, using: key, authenticating: headerAD + blob.suffix(RatchetHeader.sealedLength)).combined)
        sessions.promote(session)
        return blob
    }

    /// Decrypts a direct message from the peer, advancing the ratchet. Throws (leaving `sessions`
    /// untouched) for anything else: duplicates, our own messages, forgeries.
    public func open(_ blob: Data, me: Identity, sessions: inout DirectSessions, now: Date = Date()) throws -> ReceivedMessage {
        guard case .direct(let peer) = kind else { throw UmbraError.notForUs }
        let blob = Data(blob)
        guard blob.first == Self.ratchetBlob, blob.count > 1 + RatchetHeader.sealedLength else { throw UmbraError.notForUs }
        let sealedHeader = blob.subdata(in: 1..<(1 + RatchetHeader.sealedLength))
        let header = try RatchetHeader(try Self.decrypt(sealedHeader, key: headerKey(from: peer), ad: headerAD))

        var session: RatchetSession
        if let existing = sessions.sessions.first(where: { $0.id == header.session }) {
            session = existing
        } else if !sessions.retired.contains(header.session) {
            session = .respond(id: header.session, rootKey: sessionRoot(header.session), ourKey: me.agreement.rawRepresentation)
        } else {
            throw UmbraError.decryptionFailed
        }
        let key = try session.receivingKey(for: header, now: now)
        let plaintext = try Self.decrypt(blob.suffix(from: 1 + RatchetHeader.sealedLength), key: key, ad: headerAD + sealedHeader)
        let message = try verified(plaintext)

        var updated = sessions
        updated.promote(session)
        updated.expireSkippedKeys(now: now)
        sessions = updated
        return message
    }

    private var headerAD: Data { Data([Self.ratchetBlob]) + conversationID }

    /// One key per direction, so our own messages (echoed back by a store) are rejected immediately.
    /// Headers are hidden from servers; they would otherwise show who is talking and how much.
    private func headerKey(from sender: PublicIdentity) -> SymmetricKey {
        KDF.derive(root.data, salt: sender.signKey, info: "umbra/dm/header")
    }

    private func sessionRoot(_ id: Data) -> Data {
        KDF.derive(root.data, salt: id, info: "umbra/dm/session").data
    }
}
