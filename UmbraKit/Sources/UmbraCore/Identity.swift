import Foundation

/// A user's long-term keys. Ed25519 signs messages; X25519 derives pairwise secrets.
public struct Identity: Sendable {
    public var name: String
    public let signing: Curve25519.Signing.PrivateKey
    public let agreement: Curve25519.KeyAgreement.PrivateKey

    public init(name: String) {
        self.name = name
        signing = .init()
        agreement = .init()
    }

    public init(name: String, signingKey: Data, agreementKey: Data) throws {
        self.name = name
        signing = try .init(rawRepresentation: signingKey)
        agreement = try .init(rawRepresentation: agreementKey)
    }

    public var publicIdentity: PublicIdentity {
        PublicIdentity(
            name: name,
            signKey: signing.publicKey.rawRepresentation,
            kxKey: agreement.publicKey.rawRepresentation)
    }
}

public struct PublicIdentity: Codable, Hashable, Sendable {
    public var name: String
    public let signKey: Data
    public let kxKey: Data

    public init(name: String, signKey: Data, kxKey: Data) {
        self.name = name
        self.signKey = signKey
        self.kxKey = kxKey
    }

    /// Stable identifier for a person: independent of their chosen display name.
    public var id: String { signKey.base64URL }

    /// Short, human-comparable fingerprint for out-of-band verification, e.g. "3F2A-91C0-7B44-0E1D".
    public var fingerprint: String {
        let digest = Data(SHA256.hash(data: signKey + kxKey)).prefix(8).hex.uppercased()
        return stride(from: 0, to: digest.count, by: 4).map { i -> String in
            let start = digest.index(digest.startIndex, offsetBy: i)
            return String(digest[start..<digest.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    func verify(_ signature: Data, for message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
