import Foundation
import Network
import UmbraCore

/// Watches the local network for Umbra servers announcing themselves, and resolves each to an
/// IPv4 address and port. Lets clients follow a known server when its address changes.
final class Discovery {
    struct Found: Equatable {
        let discoveryID: String
        let host: String
        let port: Int
    }

    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    var onFound: ((Found) -> Void)?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ServerInfo.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                for result in results {
                    guard case .bonjour(let txt) = result.metadata, let id = txt["id"] else { continue }
                    self?.resolve(id: id, endpoint: result.endpoint)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Re-browse from scratch; results (and therefore resolutions) are reported again.
    func refresh() {
        guard browser != nil else { return }
        stop()
        start()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for c in resolving.values { c.cancel() }
        resolving = [:]
    }

    /// Bonjour gives a service name, not an address. Opening a TCP connection to it makes Network.framework
    /// resolve it; we read the address it picked and close immediately (the server just sees an empty
    /// connection that never says hello).
    private func resolve(id: String, endpoint: NWEndpoint) {
        guard resolving[id] == nil else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: params)
        resolving[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let address) = host {
                        let text = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
                        self?.onFound?(Found(discoveryID: id, host: text, port: Int(port.rawValue)))
                    }
                    connection.cancel()
                case .failed, .cancelled:
                    self?.resolving[id] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.resolving[id] === connection { connection.cancel() }
        }
    }
}
