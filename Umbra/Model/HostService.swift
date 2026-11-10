import Combine
import Foundation
import UmbraCore
import UmbraServer
#if canImport(UIKit)
import UIKit
#endif

/// Runs a relay server inside the app.
///
/// On iOS the app must stay in the foreground: the screen is kept awake while hosting. If the user
/// briefly switches away, a background task keeps serving for the ~30 s iOS allows; after a longer
/// suspension the listening socket is dead, so the listener is rebound on return (stored messages
/// live in the server object and survive that).
final class HostService: ObservableObject {
    @Published private(set) var server: RelayServer?
    @Published private(set) var boundPort: Int?
    @Published private(set) var error: String?
    @Published private(set) var addresses: [String] = []
    @Published private(set) var connectionCount = 0
    private var announcer: Announcer?
    private var announce = true
    private var monitor: Task<Void, Never>?
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var suspendedWhileHosting = false
    #endif

    var isRunning: Bool { server != nil }

    static var snapshotURL: URL { Vault.directory.appendingPathComponent("host-store.sealed") }

    func start(_ settings: HostSettings) async {
        guard server == nil else { return }
        error = nil
        do {
            let config = RelayConfiguration(
                name: settings.name, host: "0.0.0.0", port: settings.port, mode: settings.mode,
                retention: TimeInterval(settings.retentionHours) * 3600, accessKey: settings.accessKey,
                snapshotURL: settings.mode == .store ? Self.snapshotURL : nil,
                maxStoredBytes: settings.maxStoreMB << 20, maxConnections: 256)
            let s = try RelayServer(configuration: config, privateKey: settings.privateKey)
            let port = try await s.start()
            server = s
            boundPort = port
            announce = settings.announce
            if announce { announcer = Announcer(publicKey: s.publicKey, port: port) }
            refreshAddresses()
            setIdleTimerDisabled(true)
            startMonitor()
        } catch {
            self.error = "Could not start on port \(settings.port): \(error)"
        }
    }

    func stop() async {
        guard let s = server else { return }
        server = nil
        boundPort = nil
        monitor?.cancel()
        announcer?.stop()
        announcer = nil
        connectionCount = 0
        await s.stop()
        setIdleTimerDisabled(false)
    }

    func refreshAddresses() {
        addresses = NetworkInterfaces.lanIPv4()
    }

    func invite(host: String) -> Invite? {
        guard let server, let boundPort else { return nil }
        return server.invite(host: host, port: boundPort)
    }

    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let server = self.server else { return }
                let count = await server.connectionCount
                if count != self.connectionCount { self.connectionCount = count }
                let addresses = NetworkInterfaces.lanIPv4()
                if addresses != self.addresses { self.addresses = addresses }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Lifecycle

    func didEnterBackground() {
        #if os(iOS)
        guard isRunning, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "umbra.host") { [weak self] in
            // Grace period over: iOS is about to suspend us and the sockets will die.
            guard let self else { return }
            self.suspendedWhileHosting = true
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        #endif
    }

    func didBecomeActive() async {
        #if os(iOS)
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        guard let server else { return }
        let listening = await server.isRunning
        #if DEBUG
        print("UMBRA_HOST_RESUME suspended=\(suspendedWhileHosting) listening=\(listening)"); fflush(stdout)
        #endif
        guard suspendedWhileHosting || !listening else { return }
        suspendedWhileHosting = false
        do {
            let port = try await server.start()
            announcer?.stop()
            if announce { announcer = Announcer(publicKey: server.publicKey, port: port) }
            refreshAddresses()
            #if DEBUG
            print("UMBRA_HOST_REBOUND port=\(port)"); fflush(stdout)
            #endif
        } catch {
            self.error = "Could not resume hosting: \(error)"
        }
        #endif
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
