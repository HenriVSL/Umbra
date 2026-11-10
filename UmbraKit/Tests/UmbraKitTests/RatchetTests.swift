import Foundation
import Testing
@testable import UmbraCore

/// One side of a direct chat: identity, conversation keys and ratchet state.
private final class Party {
    let me: Identity
    let keys: ConversationKeys
    var sessions = DirectSessions()

    init(_ me: Identity, talkingTo peer: Identity) throws {
        self.me = me
        keys = try .direct(me: me, peer: peer.publicIdentity)
    }

    func send(_ text: String) throws -> Data {
        try keys.seal(MessageBody(text: text), from: me, sessions: &sessions)
    }

    func receive(_ blob: Data) throws -> String {
        try keys.open(blob, me: me, sessions: &sessions).body.text
    }

    /// Opening must fail and leave the state exactly as it was.
    func rejects(_ blob: Data) -> Bool {
        let before = sessions
        let failed = (try? receive(blob)) == nil
        return failed && sessions == before
    }
}

@Suite struct RatchetTests {
    let alice = Identity(name: "Alice")
    let bob = Identity(name: "Bob")
    let eve = Identity(name: "Eve")

    @Test func conversationBothWays() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        #expect(a.keys.tag() == b.keys.tag())
        for turn in 0..<5 {
            for i in 0..<3 { #expect(try b.receive(try a.send("a\(turn).\(i)")) == "a\(turn).\(i)") }
            #expect(try a.receive(try b.send("b\(turn)")) == "b\(turn)")
        }
        #expect(a.sessions.sessions.count == 1 && b.sessions.sessions.count == 1)

        let opened = try b.keys.open(try a.send("signed"), me: bob, sessions: &b.sessions)
        #expect(opened.sender == alice.publicIdentity)
    }

    @Test func outsidersAndOwnMessagesRejected() throws {
        let a = try Party(alice, talkingTo: bob)
        let e = try Party(eve, talkingTo: alice)
        let blob = try a.send("contact at grid 4")
        #expect(e.rejects(blob))
        #expect(e.keys.tag() != a.keys.tag())
        // A store echoes our own messages back to us; they must be ignored, not break the session.
        #expect(a.rejects(blob))
    }

    @Test func lostAndReorderedMessages() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        let m = try (0..<6).map { try a.send("m\($0)") }
        #expect(try b.receive(m[3]) == "m3")
        #expect(try b.receive(m[0]) == "m0")
        // Bob replies; Alice's next chain starts while m1, m2, m4, m5 are still in flight.
        #expect(try a.receive(try b.send("ack")) == "ack")
        let later = try a.send("new chain")
        #expect(try b.receive(later) == "new chain")
        #expect(try b.receive(m[5]) == "m5")
        #expect(try b.receive(m[1]) == "m1")
        // m2 and m4 never arrive; nothing else is affected.
        #expect(try a.receive(try b.send("still fine")) == "still fine")
    }

    @Test func duplicatesRejected() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        let first = try a.send("once"), second = try a.send("twice")
        _ = try b.receive(second)
        _ = try b.receive(first)  // from the skipped keys
        #expect(b.rejects(first))
        #expect(b.rejects(second))
    }

    @Test func tamperingRejected() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        let blob = try a.send("hi")
        for index in [1, 30, blob.count - 20, blob.count - 1] {
            var bad = blob
            bad[index] ^= 1
            #expect(b.rejects(bad))
        }
        #expect(b.rejects(blob.prefix(60)))
        #expect(try b.receive(blob) == "hi")
    }

    @Test func absurdGapRejected() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        for _ in 0...DirectSessions.maxSkip { _ = try a.send("filler") }
        #expect(b.rejects(try a.send("too far ahead")))
    }

    @Test func bothStartAtOnceAndConverge() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        let fromA = try a.send("a first"), fromB = try b.send("b first")
        #expect(try b.receive(fromA) == "a first")
        #expect(try a.receive(fromB) == "b first")
        for i in 0..<4 {
            let x = try a.send("a\(i)"), y = try b.send("b\(i)")
            #expect(try b.receive(x) == "a\(i)")
            #expect(try a.receive(y) == "b\(i)")
        }
        // Once one side speaks first, both settle on one session.
        #expect(try b.receive(try a.send("settle")) == "settle")
        #expect(try a.receive(try b.send("settled")) == "settled")
        #expect(a.sessions.sessions.first?.id == b.sessions.sessions.first?.id)
    }

    @Test func peerThatLostItsStateRecovers() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        #expect(try b.receive(try a.send("hello")) == "hello")
        #expect(try a.receive(try b.send("hi")) == "hi")
        b.sessions = DirectSessions()
        #expect(try a.receive(try b.send("i'm back")) == "i'm back")
        #expect(try b.receive(try a.send("welcome back")) == "welcome back")
    }

    /// A phone captured after reading a message cannot read it again from a stored copy.
    @Test func forwardSecrecy() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        let early = try a.send("before reply")
        _ = try b.receive(early)
        _ = try a.receive(try b.send("ack"))
        let late = try a.send("after reply")
        _ = try b.receive(late)

        #expect(b.rejects(early))
        #expect(b.rejects(late))

        // With only Bob's long-term keys: messages sent before Bob ever answered are exposed
        // (no prekey server), anything after his first answer is not.
        let fromScratch = try Party(bob, talkingTo: alice)
        #expect(try fromScratch.receive(early) == "before reply")
        let fromScratch2 = try Party(bob, talkingTo: alice)
        #expect(fromScratch2.rejects(late))
    }

    /// Someone who copied Bob's state loses access once Alice and Bob exchange fresh ratchet keys.
    @Test func healsAfterCompromise() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        _ = try b.receive(try a.send("hello"))
        _ = try a.receive(try b.send("hi"))
        let spy = try Party(bob, talkingTo: alice)
        spy.sessions = b.sessions

        let readable = try a.send("same chain")
        #expect(try spy.receive(readable) == "same chain")
        _ = try b.receive(readable)
        _ = try a.receive(try b.send("new key"))
        let healed = try a.send("after round trip")
        #expect(try b.receive(healed) == "after round trip")
        #expect(spy.rejects(healed))
    }

    @Test func receiptsAreMessages() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        let id = UUID()
        _ = try b.keys.open(try a.keys.seal(MessageBody(id: id, text: "x"), from: alice, sessions: &a.sessions), me: bob, sessions: &b.sessions)
        let receipt = try b.keys.seal(MessageBody(text: "", acks: [id]), from: bob, sessions: &b.sessions)
        let got = try a.keys.open(receipt, me: alice, sessions: &a.sessions)
        #expect(got.body.isReceipt && got.body.acks == [id])
    }

    @Test func roomKeysCannotSealDirect() throws {
        let room = ConversationKeys.room(secret: .random(32))
        var sessions = DirectSessions()
        #expect(throws: UmbraError.notForUs) { try room.seal(MessageBody(text: "x"), from: alice, sessions: &sessions) }
        let direct = try ConversationKeys.direct(me: alice, peer: bob.publicIdentity)
        #expect(throws: UmbraError.notForUs) { try direct.seal(MessageBody(text: "x"), from: alice) }
    }

    @Test func skippedKeysExpire() throws {
        let a = try Party(alice, talkingTo: bob), b = try Party(bob, talkingTo: alice)
        let lost = try a.send("lost")
        _ = try b.receive(try a.send("next"))
        #expect(b.sessions.sessions[0].skipped.count == 1)
        b.sessions.expireSkippedKeys(now: Date().addingTimeInterval(DirectSessions.skippedKeyLifetime + 1))
        #expect(b.rejects(lost))
    }
}
