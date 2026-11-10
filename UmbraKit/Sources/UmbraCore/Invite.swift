import Foundation

/// Everything is shared as `umbra://` links, which the apps render and scan as QR codes.
///
///   umbra://server?n=<name>&h=<host>&p=<port>&k=<server key>[&a=<access key>]
///   umbra://contact?n=<name>&s=<signing key>&x=<agreement key>
///   umbra://room?n=<name>&k=<room secret>
///
/// Room and server links are secrets: anyone holding them can read the room / use the server.
public enum Invite: Equatable, Sendable {
    case server(ServerInfo)
    case contact(PublicIdentity)
    case room(name: String, secret: Data)

    public var url: String {
        var c = URLComponents()
        c.scheme = "umbra"
        switch self {
        case .server(let s):
            c.host = "server"
            c.queryItems = [
                .init(name: "n", value: s.name), .init(name: "h", value: s.host),
                .init(name: "p", value: String(s.port)), .init(name: "k", value: s.publicKey.base64URL),
            ]
            if let a = s.accessKey { c.queryItems?.append(.init(name: "a", value: a.base64URL)) }
        case .contact(let p):
            c.host = "contact"
            c.queryItems = [
                .init(name: "n", value: p.name), .init(name: "s", value: p.signKey.base64URL),
                .init(name: "x", value: p.kxKey.base64URL),
            ]
        case .room(let name, let secret):
            c.host = "room"
            c.queryItems = [.init(name: "n", value: name), .init(name: "k", value: secret.base64URL)]
        }
        return c.string!
    }

    public init(url string: String) throws {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "umbra"
        else { throw UmbraError.invalidInvite }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        func key(_ k: String) throws -> Data {
            guard let v = q[k], let d = Data(base64URL: v), d.count == 32 else { throw UmbraError.invalidInvite }
            return d
        }
        let name = q["n"] ?? ""
        switch c.host {
        case "server":
            guard let host = q["h"], !host.isEmpty, let port = q["p"].flatMap(UInt16.init) else {
                throw UmbraError.invalidInvite
            }
            let access = q["a"] != nil ? try key("a") : nil
            self = .server(ServerInfo(name: name, host: host, port: Int(port), publicKey: try key("k"), accessKey: access))
        case "contact":
            self = .contact(PublicIdentity(name: name, signKey: try key("s"), kxKey: try key("x")))
        case "room":
            self = .room(name: name, secret: try key("k"))
        default:
            throw UmbraError.invalidInvite
        }
    }
}

/// How to reach and authenticate a relay server.
public struct ServerInfo: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var host: String
    public var port: Int
    /// Server's static X25519 key, pinned: connections to anyone else fail the handshake.
    public var publicKey: Data
    /// Optional pre-shared access key; servers configured with one ignore clients without it.
    public var accessKey: Data?

    /// Identity of the server is its key; host and port are just where it currently is.
    public var id: String { publicKey.base64URL }

    /// What the server announces on the local network (Bonjour TXT `id`). Derived from the public key so
    /// clients holding the invite can recognise it at a new address, without revealing the key or name.
    public var discoveryID: String { Self.discoveryID(for: publicKey) }

    public static func discoveryID(for publicKey: Data) -> String {
        Data(SHA256.hash(data: Data("umbra/discovery".utf8) + publicKey)).prefix(9).base64URL
    }

    public static let bonjourType = "_umbra._tcp"

    public init(name: String, host: String, port: Int, publicKey: Data, accessKey: Data?) {
        self.name = name
        self.host = host
        self.port = port
        self.publicKey = publicKey
        self.accessKey = accessKey
    }
}
