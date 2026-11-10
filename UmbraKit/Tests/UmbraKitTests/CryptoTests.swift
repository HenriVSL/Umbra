import Foundation
import Testing
@testable import UmbraCore

@Suite struct TransportTests {
    let server = Curve25519.KeyAgreement.PrivateKey()
    let psk = Data.random(32)

    func pair(clientPSK: Data?, serverPSK: Data?, serverKey: Data? = nil) throws -> (SecureChannel, SecureChannel) {
        let (hello, state) = try Handshake.clientStart(serverKey: serverKey ?? server.publicKey.rawRepresentation, psk: clientPSK)
        let (reply, s) = try Handshake.serverRespond(to: hello, staticKey: server, psk: serverPSK)
        return (try Handshake.clientFinish(state, response: reply), s)
    }

    @Test func roundTripBothDirections() throws {
        var (c, s) = try pair(clientPSK: psk, serverPSK: psk)
        for i in 0..<3 {
            #expect(try s.open(try c.seal(Data("hello \(i)".utf8))) == Data("hello \(i)".utf8))
            #expect(try c.open(try s.seal(Data("reply \(i)".utf8))) == Data("reply \(i)".utf8))
        }
    }

    @Test func wrongAccessKeyGetsNoReply() throws {
        // The server refuses at the hello, before doing any DH work or sending a single byte.
        for clientPSK in [Data.random(32), nil] {
            let (hello, _) = try Handshake.clientStart(serverKey: server.publicKey.rawRepresentation, psk: clientPSK)
            #expect(throws: UmbraError.handshakeFailed) { try Handshake.serverRespond(to: hello, staticKey: server, psk: psk) }
        }
        let (hello, _) = try Handshake.clientStart(serverKey: server.publicKey.rawRepresentation, psk: psk)
        var tampered = hello
        tampered[5] ^= 1
        #expect(throws: UmbraError.handshakeFailed) { try Handshake.serverRespond(to: tampered, staticKey: server, psk: psk) }
    }

    @Test func impostorServerCannotTalk() throws {
        // The client pinned key S. A server holding another key cannot validate the hello (the proof binds S),
        // and even one that skipped the check could not compute DH(ce, S) to derive the session keys.
        let impostor = Curve25519.KeyAgreement.PrivateKey()
        let (hello, _) = try Handshake.clientStart(serverKey: server.publicKey.rawRepresentation, psk: nil)
        #expect(throws: UmbraError.handshakeFailed) { try Handshake.serverRespond(to: hello, staticKey: impostor, psk: nil) }
    }

    @Test func replayAndReorderRejected() throws {
        var (c, s) = try pair(clientPSK: nil, serverPSK: nil)
        let a = try c.seal(Data("a".utf8)), b = try c.seal(Data("b".utf8))
        #expect(throws: UmbraError.decryptionFailed) { try s.open(b) }
        _ = try s.open(a)
        #expect(throws: UmbraError.decryptionFailed) { try s.open(a) }
        _ = try s.open(b)
    }
}

@Suite struct ConversationTests {
    let alice = Identity(name: "Alice")
    let bob = Identity(name: "Bob")
    let eve = Identity(name: "Eve")

    @Test func contactRequestViaInbox() throws {
        let toBob = ConversationKeys.inbox(of: bob.publicIdentity)
        let blob = try toBob.seal(MessageBody(text: "intro"), from: alice)
        let got = try ConversationKeys.inbox(of: bob.publicIdentity).open(blob, me: bob)
        #expect(got.sender == alice.publicIdentity)
        // Eve knows Bob's public identity, so she can compute the tag, but not read the request.
        #expect(throws: (any Error).self) { try ConversationKeys.inbox(of: bob.publicIdentity).open(blob, me: eve) }
    }

    @Test func roomMemberCannotRewrapAnothersIdentity() throws {
        // Eve is in the room. She takes Alice's signed message and re-encrypts it under the room key,
        // claiming Alice's signing key but her own agreement key / another name.
        let room = ConversationKeys.room(secret: ConversationKeys.newRoomSecret())
        let genuine = try room.envelope(MessageBody(text: "orders"), from: alice)
        for forgedSender in [
            PublicIdentity(name: alice.name, signKey: alice.publicIdentity.signKey, kxKey: eve.publicIdentity.kxKey),
            PublicIdentity(name: "Command", signKey: alice.publicIdentity.signKey, kxKey: alice.publicIdentity.kxKey),
        ] {
            let forged = SignedEnvelope(sender: forgedSender, body: genuine.body, signature: genuine.signature)
            #expect(throws: UmbraError.badSignature) { try room.open(try room.seal(envelope: forged), me: bob) }
        }
        #expect(try room.open(try room.seal(envelope: genuine), me: bob).sender == alice.publicIdentity)
    }

    @Test func roomMessage() throws {
        let secret = ConversationKeys.newRoomSecret()
        let ra = ConversationKeys.room(secret: secret), rb = ConversationKeys.room(secret: secret)
        let blob = try ra.seal(MessageBody(text: "rally at 0600"), from: alice)
        let got = try rb.open(blob, me: bob)
        #expect(got.body.text == "rally at 0600" && got.sender.name == "Alice")
        #expect(throws: (any Error).self) { try ConversationKeys.room(secret: .random(32)).open(blob, me: eve) }
    }

    @Test func paddingHidesLength() throws {
        let room = ConversationKeys.room(secret: .random(32))
        let short = try room.seal(MessageBody(text: "ok"), from: alice)
        let longer = try room.seal(MessageBody(text: String(repeating: "x", count: 40)), from: alice)
        #expect(short.count == longer.count)
    }

    @Test func tagsCoverRetention() {
        let room = ConversationKeys.room(secret: .random(32))
        let now = Date()
        let tags = room.tags(covering: 7 * 86_400, now: now)
        #expect(tags.count == 10)
        #expect(tags.contains(room.tag(at: now)))
        #expect(tags.contains(room.tag(at: now.addingTimeInterval(-7 * 86_400))))
    }
}

@Suite struct InviteTests {
    @Test func roundTrips() throws {
        let id = Identity(name: "Bravo 2").publicIdentity
        let invites: [Invite] = [
            .contact(id),
            .room(name: "Ops & Logistics", secret: .random(32)),
            .server(ServerInfo(name: "FOB", host: "10.0.0.5", port: 7443, publicKey: .random(32), accessKey: .random(32))),
            .server(ServerInfo(name: "Open", host: "relay.example.org", port: 443, publicKey: .random(32), accessKey: nil)),
        ]
        for invite in invites {
            #expect(try Invite(url: invite.url) == invite)
        }
    }

    @Test func rejectsGarbage() {
        for bad in ["https://x", "umbra://room?n=x&k=short", "umbra://server?h=x&p=1", "umbra://nope"] {
            #expect(throws: UmbraError.invalidInvite) { try Invite(url: bad) }
        }
    }
}
