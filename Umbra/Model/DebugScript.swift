#if DEBUG
import Foundation
import UmbraCore

/// Scripted roles for multi-simulator end-to-end tests. DEBUG builds only; release builds contain none
/// of this and print nothing.
///
///   -UmbraName <name>        identity name on first launch
///   -UmbraAutoHost           start hosting, print UMBRA_INVITE
///   -UmbraCreateRoom <name>  create a room, print UMBRA_ROOM
///   -UmbraAdd <link>         import a server/contact/room link (repeatable)
///   -UmbraSend <text>        send to every conversation once a server is online
///   -UmbraAutoAccept         accept contact requests as they arrive
///   -UmbraEcho               reply "echo: <text>" to received messages
///   -UmbraTrace              print UMBRA_RX / UMBRA_REQUEST / UMBRA_DELIVERED / UMBRA_STATUS lines
extension AppModel {
    func runDebugScript() async {
        let args = ProcessInfo.processInfo.arguments
        func values(_ flag: String) -> [String] {
            args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
        }
        func has(_ flag: String) -> Bool { args.contains(flag) }
        func out(_ line: String) { print(line); fflush(stdout) }

        if phase == .onboarding { createIdentity(name: values("-UmbraName").first ?? "Sim") }
        if let me = myInvite() { out("UMBRA_CONTACT \(me.url)") }

        if has("-UmbraTrace") || has("-UmbraEcho") {
            debugReceived = { [weak self] ref, message in
                guard let self else { return }
                if has("-UmbraTrace") { out("UMBRA_RX [\(self.title(for: ref))] \(message.senderName): \(message.text)") }
                if has("-UmbraEcho"), !message.text.hasPrefix("echo:") { self.send("echo: \(message.text)", to: ref) }
            }
            debugDelivered = { [weak self] ref, count in
                if has("-UmbraTrace") { out("UMBRA_DELIVERED [\(self?.title(for: ref) ?? "")] \(count)") }
            }
            debugRequest = { [weak self] request in
                out("UMBRA_REQUEST \(request.identity.name)")
                if has("-UmbraAutoAccept") {
                    self?.accept(request)
                    out("UMBRA_ACCEPTED \(request.identity.name)")
                }
            }
        }
        if has("-UmbraAutoHost") {
            await startHosting()
            if let invite = host.invite(host: "127.0.0.1") { out("UMBRA_INVITE \(invite.url)") }
        }
        for name in values("-UmbraCreateRoom") { out("UMBRA_ROOM \(createRoom(named: name).invite.url)") }
        for link in values("-UmbraAdd") { out("UMBRA_ADDED \((try? importInvite(link)) ?? "invalid")") }

        // Report server status changes (e.g. discovery moving a server to its announced address).
        Task {
            var last = ""
            while true {
                let line = servers.map { "\($0.info.host):\($0.info.port)=\(String(describing: status(of: $0.id)))" }.joined(separator: " ")
                if line != last, has("-UmbraTrace") { out("UMBRA_STATUS \(line)"); last = line }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        for text in values("-UmbraSend") {
            // Queue immediately; pending messages go out as soon as a server is online.
            for ref in conversations { send(text, to: ref) }
            out("UMBRA_SENT \(text) to \(conversations.count) conversations")
        }
    }
}
#endif
