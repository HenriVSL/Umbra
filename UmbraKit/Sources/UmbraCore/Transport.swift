import Foundation

/// Transport encryption between a client and a relay server.
///
/// Noise-NK-like handshake with an optional pre-shared access key:
///   C -> S : version(1) || ce || proof   (client ephemeral X25519 key, proof = HMAC(psk, S || ce)[0..<16])
///   S -> C : se                          (server ephemeral X25519 public key)
///   keys    = HKDF(DH(ce, S) || DH(ce, se), salt: psk, info: transcript)
/// Only the holder of the server's static key S (pinned via the invite QR) can derive the keys and
/// the ephemeral-ephemeral DH gives forward secrecy. The proof lets the server stay completely silent
/// towards clients without the access key, so a port scan cannot tell an Umbra server is listening.
/// A replayed hello gains nothing: the replayer cannot derive keys without the client's ephemeral secret.
public enum Handshake {
    public static let version: UInt8 = 1
    static let pskPlaceholder = Data(count: 32)

    public struct ClientState: Sendable {
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        let serverKey: Curve25519.KeyAgreement.PublicKey
        let psk: Data
    }

    /// Returns the first message to send and the state needed to finish the handshake.
    public static func clientStart(serverKey: Data, psk: Data?) throws -> (message: Data, state: ClientState) {
        let server = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverKey)
        let e = Curve25519.KeyAgreement.PrivateKey()
        let psk = psk ?? pskPlaceholder
        var msg = Data([version])
        msg.append(e.publicKey.rawRepresentation)
        msg.append(proof(psk: psk, server: serverKey, ce: e.publicKey.rawRepresentation))
        return (msg, ClientState(ephemeral: e, serverKey: server, psk: psk))
    }

    public static func clientFinish(_ state: ClientState, response: Data) throws -> SecureChannel {
        guard response.count == 32,
              let se = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: response)
        else { throw UmbraError.handshakeFailed }
        let dh1 = try state.ephemeral.sharedSecretFromKeyAgreement(with: state.serverKey).data
        let dh2 = try state.ephemeral.sharedSecretFromKeyAgreement(with: se).data
        let keys = derive(
            dh1 + dh2, psk: state.psk, server: state.serverKey.rawRepresentation,
            ce: state.ephemeral.publicKey.rawRepresentation, se: response)
        return SecureChannel(sendKey: keys.c2s, receiveKey: keys.s2c)
    }

    /// Server side: consumes the client's first message, returns the reply and the channel.
    public static func serverRespond(
        to message: Data, staticKey: Curve25519.KeyAgreement.PrivateKey, psk: Data?
    ) throws -> (reply: Data, channel: SecureChannel) {
        let psk = psk ?? pskPlaceholder
        guard message.count == 1 + 32 + proofLength, message.first == version,
              let ce = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.dropFirst().prefix(32))
        else { throw UmbraError.handshakeFailed }
        let expected = proof(psk: psk, server: staticKey.publicKey.rawRepresentation, ce: ce.rawRepresentation)
        guard constantTimeEqual(expected, message.suffix(proofLength)) else { throw UmbraError.handshakeFailed }
        let e = Curve25519.KeyAgreement.PrivateKey()
        let dh1 = try staticKey.sharedSecretFromKeyAgreement(with: ce).data
        let dh2 = try e.sharedSecretFromKeyAgreement(with: ce).data
        let reply = e.publicKey.rawRepresentation
        let keys = derive(
            dh1 + dh2, psk: psk, server: staticKey.publicKey.rawRepresentation,
            ce: ce.rawRepresentation, se: reply)
        return (reply, SecureChannel(sendKey: keys.s2c, receiveKey: keys.c2s))
    }

    static let proofLength = 16

    private static func proof(psk: Data, server: Data, ce: Data) -> Data {
        KDF.hmac(SymmetricKey(data: psk), Data("umbra/hello/v1".utf8) + server + ce).prefix(proofLength)
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ ikm: Data, psk: Data, server: Data, ce: Data, se: Data) -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        let transcript = "umbra/transport/v1|" + (server + ce + se).base64URL
        let okm = KDF.derive(ikm, salt: psk, info: transcript, count: 64).data
        return (SymmetricKey(data: okm.prefix(32)), SymmetricKey(data: okm.suffix(32)))
    }
}

/// Encrypts frames with ChaCha20-Poly1305 using implicit, strictly increasing nonces.
/// TCP preserves order, so any replayed, dropped or reordered frame fails authentication.
public struct SecureChannel: Sendable {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return box.ciphertext + box.tag
    }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 16 else { throw UmbraError.decryptionFailed }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: Self.nonce(receiveCounter), ciphertext: frame.dropLast(16), tag: frame.suffix(16))
            let plain = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            return plain
        } catch {
            throw UmbraError.decryptionFailed
        }
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var n = Data(count: 4)
        n.appendBE(counter)
        return try! ChaChaPoly.Nonce(data: n)
    }
}

/// Length-prefixed framing on the raw TCP stream: u32 big-endian length, then payload.
public enum Framing {
    public static let maxFrame = 1 << 20

    public static func encode(_ payload: Data) -> Data {
        var out = Data()
        out.appendBE(UInt32(payload.count))
        out.append(payload)
        return out
    }
}
