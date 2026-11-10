import Combine
import Foundation
import UmbraClient
import UmbraCore

/// Keeps one server connected with backoff, tracks its sync state, and reports frames to the app model.
final class ServerConnection: ObservableObject {
    enum Status: Equatable {
        case connecting
        case online(mode: ServerMode, retention: TimeInterval)
        case offline(String)
        case rejected

        var isOnline: Bool { if case .online = self { true } else { false } }
    }

    let serverID: String
    @Published private(set) var status: Status = .connecting
    var sync: SyncState
    private var send: AsyncStream<ClientFrame>.Continuation?
    private var task: Task<Void, Never>?
    private var info: ServerInfo?
    private var onFrame: ((ServerFrame) -> Void)?
    private var wasOnline = false
    /// Bumped on every (re)start. A superseded loop may still be unwinding (e.g. a slow connect being
    /// cancelled); it must never touch state that now belongs to the new loop.
    private var generation = 0

    init(serverID: String, sync: SyncState) {
        self.serverID = serverID
        self.sync = sync
    }

    var mode: ServerMode? { if case .online(let m, _) = status { m } else { nil } }
    var retention: TimeInterval { if case .online(_, let r) = status { r } else { 0 } }

    func start(info: ServerInfo, onFrame: @escaping (ServerFrame) -> Void) {
        self.info = info
        self.onFrame = onFrame
        task?.cancel()
        send?.finish()
        generation += 1
        let generation = generation
        task = Task { [weak self] in
            var delay: Double = 1
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                let (outgoing, send) = AsyncStream.makeStream(of: ClientFrame.self)
                self.send = send
                self.status = .connecting
                let pinger = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(25))
                        send.yield(.ping)
                    }
                }
                var outcome: Status
                do {
                    try await RelayClient.session(server: info, outgoing: outgoing) { frame in
                        await MainActor.run {
                            guard self.generation == generation else { return }
                            self.received(frame)
                        }
                    }
                    outcome = .offline("Disconnected")
                } catch UmbraError.handshakeFailed where !self.status.isOnline {
                    outcome = .rejected
                } catch {
                    outcome = .offline(Self.describe(error))
                }
                pinger.cancel()
                send.finish()
                guard self.generation == generation, !Task.isCancelled else { return }
                self.status = outcome
                self.send = nil
                if self.wasOnline { delay = 1 }
                if outcome == .rejected { delay = 30 }
                self.wasOnline = false
                self.sync.disconnected()
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    private func received(_ frame: ServerFrame) {
        if case .welcome(_, let mode, let retention, _, _) = frame {
            status = .online(mode: mode, retention: TimeInterval(retention))
            wasOnline = true
        }
        onFrame?(frame)
    }

    /// Reconnect now instead of waiting out the backoff (e.g. app returned to the foreground,
    /// or the server was found at a new address).
    func reconnect(info newInfo: ServerInfo? = nil) {
        guard let onFrame, let info = newInfo ?? info else { return }
        start(info: info, onFrame: onFrame)
    }

    func stop() {
        generation += 1
        task?.cancel()
        send?.finish()
        task = nil
        sync.disconnected()
        status = .offline("Disabled")
    }

    @discardableResult
    func yield(_ frames: [ClientFrame]) -> Bool {
        guard status.isOnline, let send else { return false }
        for frame in frames { send.yield(frame) }
        return true
    }

    private static func describe(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("connectTimeout") { return "Unreachable" }
        if text.localizedCaseInsensitiveContains("connection refused") { return "Refused" }
        return "Offline"
    }
}
