#if canImport(CryptoKit)
@_exported import CryptoKit
#else
@_exported import Crypto
#endif
import Foundation

public enum UmbraError: Error, Equatable, Sendable {
    case malformed
    case decryptionFailed
    case badSignature
    case handshakeFailed
    case frameTooLarge
    case invalidInvite
    case notForUs
}

extension Data {
    /// URL-safe base64 without padding, used in invite links.
    public var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    public static func random(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }

    public func readBE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, count >= offset + size else { return nil }
        var v: T = 0
        for b in self[(startIndex + offset)..<(startIndex + offset + size)] { v = (v << 8) | T(b) }
        return v
    }
}

enum KDF {
    static func derive(_ ikm: Data, salt: Data, info: String, count: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: Data(info.utf8), outputByteCount: count)
    }

    static func hmac(_ key: SymmetricKey, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }
}

extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}

extension SharedSecret {
    var data: Data { withUnsafeBytes { Data($0) } }
}

/// Plaintext padding to fixed-size buckets so ciphertext length leaks little about content.
enum Padding {
    static let bucket = 256

    static func pad(_ data: Data) -> Data {
        var out = Data()
        out.appendBE(UInt32(data.count))
        out.append(data)
        let total = ((out.count + bucket - 1) / bucket) * bucket
        out.append(Data(count: total - out.count))
        return out
    }

    static func unpad(_ data: Data) throws -> Data {
        guard let len = data.readBE(UInt32.self, at: 0), Int(len) <= data.count - 4 else { throw UmbraError.malformed }
        return data.subdata(in: (data.startIndex + 4)..<(data.startIndex + 4 + Int(len)))
    }
}
