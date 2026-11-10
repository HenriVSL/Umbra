import Foundation
import UmbraServer
import UmbraCore
import UmbraQR

let usage = """
    umbra-server — zero-log relay for Umbra encrypted chat

    USAGE: umbra-server [options]

      --name <name>          Server name shown to users            (default: Umbra)
      --listen <addr>        Address to bind                        (default: 0.0.0.0)
      --port <port>          TCP port                               (default: 7443)
      --public-host <host>   Address clients dial, put in the QR. An IP, a DNS name, or "auto":
                             detect the public address (asks a STUN server if this machine is
                             behind NAT) and follow it if it changes.
                             (default: a public address on this machine, else the first LAN IPv4)
      --mode relay|store     relay: forward only, nothing retained  (default: relay)
                             store: hold encrypted blobs until TTL
      --retention <dur>      Store-mode TTL, e.g. 12h, 7d           (default: 7d)
      --persist              Store mode: keep an encrypted snapshot next to the key file
      --max-store <MB>       Store mode: memory cap, oldest evicted first  (default: 256)
      --open                 No access key: anyone with the server key may connect
      --no-announce          Don't announce on the LAN (Bonjour; lets clients follow IP changes)
      --data-dir <path>      Holds server.key (0600)                (default: ~/.umbra-server)
      --rotate-access-key    Generate a new access key (revokes the old QR)
      --qr-file <path>       Where to write the invite QR as JPEG   (default: <data-dir>/invite-qr.jpg)
      --no-qr-file           Don't write the JPEG
      --print-invite         Print the invite even when output isn't a terminal (e.g. under systemd)
      -h, --help

    The server never writes logs. At startup it shows the invite as a QR code in the terminal and writes
    it as a JPEG (mode 0600); scan either from the app. When output goes to a log (systemd, a pipe), the
    invite is not printed, so it never ends up in a journal; use the JPEG instead.
    """

setvbuf(stdout, nil, _IOLBF, 0)

var options: [String: String] = [:]
var flags: Set<String> = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "--persist", "--open", "--rotate-access-key", "--no-announce", "--no-qr-file", "--print-invite": flags.insert(arg)
    case "--name", "--listen", "--port", "--public-host", "--mode", "--retention", "--data-dir", "--max-store", "--qr-file":
        guard let value = args.popFirst() else { fail("missing value for \(arg)") }
        options[arg] = value
    default: fail("unknown option \(arg)")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func parseDuration(_ s: String) -> TimeInterval? {
    let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86_400]
    guard let unit = s.last, let mult = units[unit], let n = Double(s.dropLast()) else { return Double(s) }
    return n * mult
}

// MARK: Key file

struct KeyFile: Codable {
    var privateKey: Data
    var accessKey: Data?
}

let dataPath = ((options["--data-dir"] ?? "~/.umbra-server") as NSString).expandingTildeInPath
let keyURL = URL(fileURLWithPath: dataPath).appendingPathComponent("server.key")
try FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

var keys: KeyFile
if let data = try? Data(contentsOf: keyURL), let existing = try? JSONDecoder().decode(KeyFile.self, from: data) {
    keys = existing
} else {
    keys = KeyFile(privateKey: RelayServer.generatePrivateKey(), accessKey: Data.random(32))
}
if flags.contains("--rotate-access-key") || (keys.accessKey == nil && !flags.contains("--open")) {
    keys.accessKey = Data.random(32)
}
try JSONEncoder().encode(keys).write(to: keyURL, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

// MARK: Configuration

guard let mode = ServerMode(rawValue: options["--mode"] ?? "relay") else { fail("mode must be relay or store") }
guard let port = Int(options["--port"] ?? "7443"), (1...65535).contains(port) else { fail("invalid port") }
guard let retention = parseDuration(options["--retention"] ?? "7d"), retention > 0 else { fail("invalid retention") }
guard let maxStoreMB = Int(options["--max-store"] ?? "256"), maxStoreMB > 0 else { fail("invalid --max-store") }

let config = RelayConfiguration(
    name: options["--name"] ?? "Umbra",
    host: options["--listen"] ?? "0.0.0.0",
    port: port,
    mode: mode,
    retention: retention,
    accessKey: flags.contains("--open") ? nil : keys.accessKey,
    snapshotURL: flags.contains("--persist") ? URL(fileURLWithPath: dataPath).appendingPathComponent("store.sealed") : nil,
    maxStoredBytes: maxStoreMB << 20)

let server = try RelayServer(configuration: config, privateKey: keys.privateKey)
let bound = try await server.start()

#if canImport(dnssd)
let announcer = flags.contains("--no-announce") ? nil : Announcer(publicKey: server.publicKey, port: bound)
#else
let announcer: Any? = nil
#endif
let announceNote = announcer != nil
    ? "Announced on the local network as \"umbra-\(ServerInfo.discoveryID(for: server.publicKey).prefix(6))\"."
    : (flags.contains("--no-announce") ? "Not announced on the local network." : """
    LAN announcement needs Avahi on Linux. Create /etc/avahi/services/umbra.service with:
      <service-group><name>umbra-\(ServerInfo.discoveryID(for: server.publicKey).prefix(6))</name><service>
      <type>_umbra._tcp</type><port>\(bound)</port>
      <txt-record>id=\(ServerInfo.discoveryID(for: server.publicKey))</txt-record></service></service-group>
    """)

let hostOption = options["--public-host"]
let autoHost = hostOption == "auto"
let interactive = isatty(STDOUT_FILENO) == 1 || flags.contains("--print-invite")

/// The address to put in the invite, and how it was chosen.
@MainActor func dialAddress() async -> (host: String, how: String) {
    if let hostOption, !autoHost { return (hostOption, "set with --public-host") }
    if let found = await PublicAddress.detect(allowSTUN: autoHost) {
        return found.behindNAT
            ? (found.address, "public address reported by \(found.source); this machine is behind NAT, so the router must forward TCP port \(bound) here")
            : (found.address, "public address of this machine")
    }
    let lan = NetworkInterfaces.lanIPv4().first ?? "127.0.0.1"
    return (lan, autoHost
        ? "no public address found (no internet?), using the LAN address"
        : "LAN address; use --public-host auto (or an address) for clients on the internet")
}

/// Writes the QR image and, in a terminal, shows the invite.
@MainActor func publishInvite(host: String) throws {
    let link = server.invite(host: host, port: bound).url
    let qr = try QRCode(text: link)
    if !flags.contains("--no-qr-file") {
        let qrPath = options["--qr-file"].map { ($0 as NSString).expandingTildeInPath } ?? dataPath + "/invite-qr.jpg"
        // Created 0600 before any content is written: the image grants use of the server.
        _ = FileManager.default.createFile(atPath: qrPath, contents: nil, attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: qrPath)
        try qr.jpeg().write(to: URL(fileURLWithPath: qrPath))
        print("Invite QR written to \(qrPath) (secret: anyone with it can use this server)")
    }
    if interactive {
        print("""

            Invite (secret — anyone with it can use this server):
            \(link)

            \(qr.terminalString())

            """)
    } else {
        print("Output is not a terminal, so the invite is not printed (use --print-invite to override).")
    }
}

let dial = await dialAddress()
print("""
    Umbra relay "\(config.name)" listening on \(config.host):\(bound) — mode: \(mode.rawValue)\
    \(mode == .store ? ", retention \(Int(retention))s\(config.snapshotURL != nil ? ", encrypted snapshot" : ", RAM only")" : "")
    Access: \(config.accessKey == nil ? "OPEN (server key only)" : "restricted by access key")
    Clients dial: \(dial.host):\(bound) (\(dial.how))
    \(announceNote)
    """)
try publishInvite(host: dial.host)

// In auto mode, follow address changes (e.g. a home connection with a dynamic IP). Clients holding the
// old QR can't follow over the internet, so a DNS name is the better fix where one is available.
if autoHost {
    Task { @MainActor in
        var current = dial.host
        while true {
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            let next = await dialAddress()
            // A failed lookup (internet briefly down) must not flip the invite to a LAN address.
            guard next.host != current, PublicAddress.isPublic(next.host) else { continue }
            print("Public address changed from \(current) to \(next.host): new QR below/in the file. Clients must rescan it.")
            current = next.host
            try? publishInvite(host: current)
        }
    }
}

// Exit cleanly on SIGINT/SIGTERM so store-mode snapshots are flushed.
let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        Task {
            #if canImport(dnssd)
            announcer?.stop()
            #endif
            await server.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
_ = signals

try await Task.sleep(nanoseconds: .max)
