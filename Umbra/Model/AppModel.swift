import Combine
import Foundation
import UmbraClient
import UmbraCore

/// App state and behaviour: identity, contacts, rooms, servers, and routing between them.
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case onboarding
        case ready
        case locked(String)
    }

    @Published private(set) var phase: Phase = .onboarding
    @Published private(set) var state: VaultState?
    @Published private(set) var identity: Identity?
    @Published private(set) var connections: [String: ServerConnection] = [:]
    let host = HostService()
    /// Views observe only this model; changes in the host and connections are passed on.
    private var hostChanges: AnyCancellable?
    private var connectionChanges: [String: AnyCancellable] = [:]
    private let discovery = Discovery()

    /// Which conversation a subscribed tag belongs to.
    private enum Target { case conversation(ConversationRef), inbox }
    private var tagTargets: [Tag: Target] = [:]
    private var keyCache: [ConversationRef: ConversationKeys] = [:]
    /// Publish refs awaiting the server's acknowledgement, per server.
    private var inFlight: [String: [UInt32: UUID]] = [:]
    private var nextRef: UInt32 = 1
    private var saveTask: Task<Void, Never>?
    /// Ids of received direct messages still to confirm, per contact.
    private var pendingReceipts: [String: [UUID]] = [:]
    private var receiptTask: Task<Void, Never>?
    private var housekeeping: Task<Void, Never>?
    private var subscribedEpoch: UInt64 = 0
    #if DEBUG
    /// Test hooks (DEBUG builds only, see DebugScript.swift).
    var debugReceived: ((ConversationRef, ChatMessage) -> Void)?
    var debugRequest: ((ContactRequest) -> Void)?
    var debugDelivered: ((ConversationRef, Int) -> Void)?
    #endif

    init() {
        hostChanges = host.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        switch Vault.load() {
        case .empty: phase = .onboarding
        case .loaded(let saved): load(saved)
        case .unreadable(let reason): phase = .locked(reason)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-Umbra") }) {
            Task { await runDebugScript() }
        }
        #endif
    }

    private func load(_ saved: VaultState) {
        state = saved
        identity = try? Identity(name: saved.name, signingKey: saved.signingKey, agreementKey: saved.agreementKey)
        phase = .ready
        purgeExpiredMessages()
        discovery.onFound = { [weak self] found in self?.discovered(found) }
        discovery.start()
        for server in saved.servers where server.enabled && !server.isLocalHost { connect(server) }
        if saved.host.autoStart { Task { await startHosting() } }
        startHousekeeping()
    }

    func createIdentity(name: String) {
        let me = Identity(name: name.trimmingCharacters(in: .whitespaces))
        let host = HostSettings(
            privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, accessKey: Data.random(32),
            name: "\(me.name)'s relay")
        load(VaultState(
            name: me.name, signingKey: me.signing.rawRepresentation, agreementKey: me.agreement.rawRepresentation,
            host: host))
        save()
    }

    /// Abandons a vault that cannot be opened. Irreversible.
    func eraseUnreadableVault() {
        Vault.wipe()
        phase = .onboarding
    }

    func retryUnlock() {
        if case .loaded(let saved) = Vault.load() { load(saved) }
    }

    // MARK: Lookups

    var contacts: [Contact] { state?.contacts ?? [] }
    var rooms: [Room] { state?.rooms ?? [] }
    var servers: [ServerEntry] { state?.servers ?? [] }
    var requests: [ContactRequest] { state?.requests ?? [] }
    var onlineCount: Int { connections.values.filter(\.status.isOnline).count }

    func contact(_ id: String) -> Contact? { contacts.first { $0.id == id } }
    func room(_ id: String) -> Room? { rooms.first { $0.id == id } }

    func title(for ref: ConversationRef) -> String {
        switch ref {
        case .direct(let id): contact(id)?.identity.name ?? "Unknown"
        case .room(let id): room(id)?.name ?? "Room"
        }
    }

    func messages(in ref: ConversationRef) -> [ChatMessage] { state?.messages[ref] ?? [] }
    func lastMessage(in ref: ConversationRef) -> ChatMessage? { state?.messages[ref]?.last }

    /// Conversations ordered by latest activity.
    var conversations: [ConversationRef] {
        let refs = rooms.map { ConversationRef.room(roomID: $0.id) } + contacts.map { .direct(contactID: $0.id) }
        return refs.sorted { (lastMessage(in: $0)?.sentAt ?? .distantPast) > (lastMessage(in: $1)?.sentAt ?? .distantPast) }
    }

    /// How to show a room message's author. Names are self-chosen, so anyone can call themselves
    /// "Command": known contacts show the name *you* saved; strangers show their key fingerprint too.
    func senderLabel(for message: ChatMessage) -> (name: String, trusted: Bool) {
        if let contact = contact(message.senderID) { return (contact.identity.name, contact.verified) }
        let tag = message.sender.map { " · " + $0.fingerprint.prefix(4) } ?? ""
        return (message.senderName + tag, false)
    }

    private func keys(for ref: ConversationRef) -> ConversationKeys? {
        if let cached = keyCache[ref] { return cached }
        guard let identity else { return nil }
        let keys: ConversationKeys?
        switch ref {
        case .direct(let id): keys = contact(id).flatMap { try? ConversationKeys.direct(me: identity, peer: $0.identity) }
        case .room(let id): keys = room(id).map { ConversationKeys.room(secret: $0.secret) }
        }
        keyCache[ref] = keys
        return keys
    }

    // MARK: Sending

    func send(_ text: String, to ref: ConversationRef) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity, !text.isEmpty else { return }
        let message = ChatMessage(
            id: UUID(), conversation: ref, senderID: identity.publicIdentity.id, senderName: identity.name,
            sender: identity.publicIdentity, text: text, sentAt: Date(), status: .pending)
        state?.messages[ref, default: []].append(message)
        if sealedBlob(for: message) == nil { save() }
        for connection in connections.values where connection.status.isOnline { publish(message, via: connection) }
    }

    /// Re-sends a message nobody was listening for (relay-only servers).
    func retry(_ message: ChatMessage) {
        guard message.status == .unheard else { return }
        setStatus(.pending, of: message.id, in: message.conversation)
        for connection in connections.values where connection.status.isOnline { publish(message, via: connection) }
    }

    private func publish(_ message: ChatMessage, via connection: ServerConnection) {
        guard let keys = keys(for: message.conversation), let blob = sealedBlob(for: message) else { return }
        let ref = nextRef
        nextRef &+= 1
        if connection.yield([.publish(ref: ref, tag: keys.tag(), blob: blob)]) {
            inFlight[connection.serverID, default: [:]][ref] = message.id
        }
    }

    /// The message's ciphertext, sealed on first use and kept until a server accepts it. A newly sealed
    /// message is written to disk before it can leave: if the app died after sending but before saving,
    /// it would come back with an older ratchet state and break the session for the peer.
    private func sealedBlob(for message: ChatMessage) -> Data? {
        if let blob = state?.outbox[message.id] { return blob }
        guard let blob = seal(MessageBody(id: message.id, sentAt: message.sentAt, text: message.text), in: message.conversation)
        else { return nil }
        state?.outbox[message.id] = blob
        saveNow()
        return blob
    }

    /// Direct chats go through the contact's ratchet (advancing it); rooms use the room key.
    private func seal(_ body: MessageBody, in ref: ConversationRef) -> Data? {
        guard let identity, let keys = keys(for: ref) else { return nil }
        guard case .direct(let contactID) = ref else { return try? keys.seal(body, from: identity) }
        var sessions = state?.sessions[contactID] ?? DirectSessions()
        guard let blob = try? keys.seal(body, from: identity, sessions: &sessions) else { return nil }
        state?.sessions[contactID] = sessions
        return blob
    }

    private func queueReceipt(for messageID: UUID, from contactID: String) {
        pendingReceipts[contactID, default: []].append(messageID)
        guard receiptTask == nil else { return }
        // Batch a burst (e.g. a backlog arriving) into one receipt per contact.
        receiptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.receiptTask = nil
            self?.sendReceipts()
        }
    }

    /// A receipt tells the sender its messages arrived. It also carries our next ratchet key, which ends
    /// the sender's dependence on our long-term key even if we never reply. Without a server online,
    /// receipts wait for the next connection.
    private func sendReceipts() {
        let online = connections.values.filter(\.status.isOnline)
        guard !online.isEmpty, !pendingReceipts.isEmpty else { return }
        var frames: [ClientFrame] = []
        for (contactID, ids) in pendingReceipts {
            let ref = ConversationRef.direct(contactID: contactID)
            guard let keys = keys(for: ref) else { continue }
            for start in stride(from: 0, to: ids.count, by: 64) {
                let chunk = Array(ids[start..<min(start + 64, ids.count)])
                if let blob = seal(MessageBody(text: "", acks: chunk), in: ref) {
                    frames.append(.publish(ref: 0, tag: keys.tag(), blob: blob))
                }
            }
        }
        pendingReceipts = [:]
        saveNow()
        for connection in online { connection.yield(frames) }
    }

    private func markDelivered(_ ids: [UUID], in ref: ConversationRef) {
        let ids = Set(ids)
        guard var list = state?.messages[ref] else { return }
        var count = 0
        for i in list.indices where ids.contains(list[i].id) && list[i].isOutgoing && list[i].status != .delivered {
            list[i].status = .delivered
            state?.outbox[list[i].id] = nil
            count += 1
        }
        state?.messages[ref] = list
        #if DEBUG
        if count > 0 { debugDelivered?(ref, count) }
        #endif
    }

    /// Sends a contact request into the peer's inbox so they can add us back without scanning.
    private func sendIntro(to peer: PublicIdentity, via connection: ServerConnection) {
        guard let identity else { return }
        let inbox = ConversationKeys.inbox(of: peer)
        guard let blob = try? inbox.seal(MessageBody(text: ""), from: identity) else { return }
        connection.yield([.publish(ref: 0, tag: inbox.tag(), blob: blob)])
    }

    private func flushPending(via connection: ServerConnection) {
        let pending = state?.messages.values.flatMap { $0.filter { $0.status == .pending } } ?? []
        for message in pending {
            publish(message, via: connection)
        }
        for id in state?.pendingIntros ?? [] {
            if let peer = contact(id)?.identity { sendIntro(to: peer, via: connection) }
        }
        if !(state?.pendingIntros.isEmpty ?? true) {
            state?.pendingIntros = []
            save()
        }
        sendReceipts()
    }

    private func setStatus(_ status: ChatMessage.Status, of id: UUID, in ref: ConversationRef) {
        guard let i = state?.messages[ref]?.firstIndex(where: { $0.id == id }) else { return }
        state?.messages[ref]?[i].status = status
        if status == .sent { state?.outbox[id] = nil }
        save()
    }

    // MARK: Receiving

    private func handle(_ frame: ServerFrame, from serverID: String) {
        guard let connection = connections[serverID] else { return }
        if case .welcome(_, let mode, _, let instance, _) = frame {
            connection.yield(connection.sync.connected(mode: mode, instance: instance, desired: desiredTags(for: connection)))
            subscribedEpoch = ConversationKeys.epoch(of: Date())
            flushPending(via: connection)
        } else {
            connection.yield(connection.sync.received(frame))
        }

        switch frame {
        case .deliver(_, let tag, let blob):
            receive(blob, tag: tag)
        case .published(let ref, _, let recipients):
            guard let id = inFlight[serverID]?.removeValue(forKey: ref),
                  let message = state?.messages.values.joined().first(where: { $0.id == id }),
                  message.status == .pending || message.status == .unheard
            else { break }
            // Relay-only servers forward to whoever is listening right now; zero listeners means undelivered.
            let delivered = connection.mode == .store || recipients > 0
            setStatus(delivered ? .sent : .unheard, of: id, in: message.conversation)
        default:
            break
        }
        persistSync(of: connection)
    }

    private func receive(_ blob: Data, tag: Tag) {
        guard let identity, let target = tagTargets[tag] else { return }
        switch target {
        case .inbox:
            guard let request = try? ConversationKeys.inbox(of: identity.publicIdentity).open(blob, me: identity),
                  request.sender.signKey != identity.publicIdentity.signKey,
                  contact(request.sender.id) == nil
            else { return }
            state?.requests.removeAll { $0.id == request.sender.id }
            state?.requests.append(ContactRequest(identity: request.sender, receivedAt: Date()))
            #if DEBUG
            debugRequest?(state!.requests.last!)
            #endif
        case .conversation(let ref):
            guard let keys = keys(for: ref) else { return }
            let message: ReceivedMessage
            if case .direct(let contactID) = ref {
                var sessions = state?.sessions[contactID] ?? DirectSessions()
                guard let opened = try? keys.open(blob, me: identity, sessions: &sessions) else { return }
                state?.sessions[contactID] = sessions
                message = opened
                if let acks = opened.body.acks {
                    markDelivered(acks, in: ref)
                    break
                }
                queueReceipt(for: opened.body.id, from: contactID)
            } else {
                guard let opened = try? keys.open(blob, me: identity) else { return }
                message = opened
            }
            guard !(state?.messages[ref]?.contains { $0.id == message.body.id } ?? false) else { break }
            if let lifetime = state?.messageLifetimeHours,
               message.body.sentAt < Date().addingTimeInterval(-Double(lifetime) * 3600) { break }
            let mine = message.sender.signKey == identity.publicIdentity.signKey
            var list = state?.messages[ref] ?? []
            list.append(ChatMessage(
                id: message.body.id, conversation: ref, senderID: message.sender.id, senderName: message.sender.name,
                sender: message.sender, text: message.body.text, sentAt: message.body.sentAt,
                status: mine ? .sent : .received))
            if list.count > 1, list[list.count - 2].sentAt > list[list.count - 1].sentAt { list.sort { $0.sentAt < $1.sentAt } }
            state?.messages[ref] = list
            #if DEBUG
            if !mine { debugReceived?(ref, list.first { $0.id == message.body.id }!) }
            #endif
        }
        save()
    }

    private func persistSync(of connection: ServerConnection) {
        guard let i = state?.servers.firstIndex(where: { $0.id == connection.serverID }),
              state?.servers[i].cursor != connection.sync.cursor || state?.servers[i].instance != connection.sync.instance
        else { return }
        state?.servers[i].cursor = connection.sync.cursor
        state?.servers[i].instance = connection.sync.instance
        save()
    }

    // MARK: Subscriptions

    /// Every tag this client listens on at `connection`: our inbox plus each conversation, covering the
    /// server's retention window (stored messages may be under older daily tags).
    private func desiredTags(for connection: ServerConnection) -> Set<Tag> {
        guard let identity else { return [] }
        let window = connection.mode == .store ? connection.retention : 0
        var tags = Set<Tag>()
        func add(_ keys: ConversationKeys, _ target: Target) {
            for tag in keys.tags(covering: window) {
                tags.insert(tag)
                tagTargets[tag] = target
            }
        }
        add(.inbox(of: identity.publicIdentity), .inbox)
        for ref in conversations { if let k = keys(for: ref) { add(k, .conversation(ref)) } }
        return tags
    }

    private func resubscribeAll() {
        keyCache = [:]
        tagTargets = [:]
        for connection in connections.values where connection.status.isOnline {
            connection.yield(connection.sync.update(desired: desiredTags(for: connection)))
        }
        subscribedEpoch = ConversationKeys.epoch(of: Date())
    }

    private func startHousekeeping() {
        housekeeping?.cancel()
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                // Tags rotate daily; follow the rotation.
                if ConversationKeys.epoch(of: Date()) != self.subscribedEpoch { self.resubscribeAll() }
                self.purgeExpiredMessages()
                if self.connections.values.contains(where: { !$0.status.isOnline }) { self.discovery.refresh() }
            }
        }
    }

    // MARK: Invites

    /// Applies a scanned/pasted `umbra://` link. `scannedInPerson` marks contacts as verified: only a
    /// camera scan proves the code came from the person standing in front of you.
    @discardableResult
    func importInvite(_ link: String, scannedInPerson: Bool = false) throws -> String {
        guard let identity else { throw UmbraError.invalidInvite }
        switch try Invite(url: link) {
        case .contact(let peer):
            guard peer.signKey != identity.publicIdentity.signKey else { return "That's your own code" }
            addContact(peer, verified: scannedInPerson, introduce: true)
            return "Added \(peer.name)"
        case .room(let name, let secret):
            let room = Room(name: name.isEmpty ? "Room" : name, secret: secret)
            if self.room(room.id) == nil {
                state?.rooms.append(room)
                save()
                resubscribeAll()
            }
            return "Joined \(room.name)"
        case .server(let info):
            addServer(info)
            return "Added server \(info.name.isEmpty ? info.host : info.name)"
        }
    }

    func myInvite() -> Invite? { identity.map { .contact($0.publicIdentity) } }

    private func addContact(_ peer: PublicIdentity, verified: Bool, introduce: Bool) {
        if let i = state?.contacts.firstIndex(where: { $0.id == peer.id }) {
            // Same signing key. Only accept a changed agreement key from a verified (camera) source.
            if verified || state?.contacts[i].identity.kxKey == peer.kxKey {
                if state?.contacts[i].identity.kxKey != peer.kxKey { state?.sessions[peer.id] = nil }
                state?.contacts[i].identity = peer
            }
            if verified { state?.contacts[i].verified = true }
        } else {
            state?.contacts.append(Contact(identity: peer, verified: verified))
            if introduce {
                let online = connections.values.filter(\.status.isOnline)
                if online.isEmpty { state?.pendingIntros.append(peer.id) }
                for connection in online { sendIntro(to: peer, via: connection) }
            }
        }
        state?.requests.removeAll { $0.id == peer.id }
        save()
        resubscribeAll()
    }

    func accept(_ request: ContactRequest) {
        addContact(request.identity, verified: false, introduce: false)
    }

    func ignore(_ request: ContactRequest) {
        state?.requests.removeAll { $0.id == request.id }
        save()
    }

    /// Adds a room member as a contact and sends them a contact request.
    func addContact(fromMessage message: ChatMessage) {
        guard let sender = message.sender, sender.signKey != identity?.publicIdentity.signKey else { return }
        addContact(sender, verified: false, introduce: true)
    }

    func canAddContact(from message: ChatMessage) -> Bool {
        guard case .room = message.conversation, let sender = message.sender else { return false }
        return sender.signKey != identity?.publicIdentity.signKey && contact(sender.id) == nil
    }

    func createRoom(named name: String) -> Room {
        let room = Room(name: name.isEmpty ? "Room" : name, secret: ConversationKeys.newRoomSecret())
        state?.rooms.append(room)
        save()
        resubscribeAll()
        return room
    }

    func setVerified(_ contactID: String, _ verified: Bool) {
        guard let i = state?.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        state?.contacts[i].verified = verified
        save()
    }

    func delete(_ ref: ConversationRef) {
        dropOutbox(of: state?.messages[ref] ?? [])
        state?.messages[ref] = nil
        switch ref {
        case .direct(let id):
            state?.contacts.removeAll { $0.id == id }
            state?.sessions[id] = nil
        case .room(let id): state?.rooms.removeAll { $0.id == id }
        }
        save()
        resubscribeAll()
    }

    func clearMessages(in ref: ConversationRef) {
        dropOutbox(of: state?.messages[ref] ?? [])
        state?.messages[ref] = nil
        save()
    }

    private func dropOutbox(of messages: [ChatMessage]) {
        for message in messages { state?.outbox[message.id] = nil }
    }

    // MARK: Servers

    func addServer(_ info: ServerInfo, isLocalHost: Bool = false) {
        if let i = state?.servers.firstIndex(where: { $0.id == info.id }) {
            state?.servers[i].info = info
            state?.servers[i].enabled = true
            state?.servers[i].isLocalHost = isLocalHost
        } else {
            state?.servers.append(ServerEntry(info: info, isLocalHost: isLocalHost))
        }
        save()
        if let entry = servers.first(where: { $0.id == info.id }) {
            if let connection = connections[entry.id] { connection.reconnect(info: entry.info) } else { connect(entry) }
        }
    }

    func setEnabled(_ serverID: String, _ enabled: Bool) {
        guard let i = state?.servers.firstIndex(where: { $0.id == serverID }) else { return }
        state?.servers[i].enabled = enabled
        save()
        if enabled { connect(state!.servers[i]) } else { disconnect(serverID) }
    }

    func removeServer(_ serverID: String) {
        disconnect(serverID)
        state?.servers.removeAll { $0.id == serverID }
        save()
    }

    func status(of serverID: String) -> ServerConnection.Status {
        connections[serverID]?.status ?? .offline("Disabled")
    }

    private func connect(_ entry: ServerEntry) {
        disconnect(entry.id)
        let connection = ServerConnection(serverID: entry.id, sync: SyncState(instance: entry.instance, cursor: entry.cursor))
        connections[entry.id] = connection
        connectionChanges[entry.id] = connection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        let id = entry.id
        connection.start(info: entry.info) { [weak self] frame in self?.handle(frame, from: id) }
    }

    private func disconnect(_ serverID: String) {
        connections.removeValue(forKey: serverID)?.stop()
        connectionChanges[serverID] = nil
        inFlight[serverID] = nil
    }

    /// A known server announced itself on the LAN. If we can't currently reach it, follow it to the
    /// announced address. The pinned key still authenticates it, so a fake announcement gains nothing.
    private func discovered(_ found: Discovery.Found) {
        guard let entry = servers.first(where: { $0.info.discoveryID == found.discoveryID && !$0.isLocalHost && $0.enabled }),
              !(connections[entry.id]?.status.isOnline ?? false),
              entry.info.host != found.host || entry.info.port != found.port
        else { return }
        var info = entry.info
        info.host = found.host
        info.port = found.port
        addServer(info)
    }

    // MARK: Lifecycle

    func didEnterBackground() {
        host.didEnterBackground()
        if let state { try? Vault.save(state) }
    }

    func didBecomeActive() async {
        await host.didBecomeActive()
        // Sockets may have died while suspended: reconnect anything not online now instead of waiting
        // out the backoff, and nudge online ones so a dead socket is noticed quickly.
        for connection in connections.values {
            if connection.status.isOnline { connection.yield([.ping]) } else { connection.reconnect() }
        }
        discovery.refresh()
    }

    // MARK: Hosting

    var hostSettings: HostSettings {
        get { state?.host ?? HostSettings(privateKey: Data(), accessKey: nil, name: "") }
        set {
            state?.host = newValue
            save()
        }
    }

    func startHosting() async {
        await host.start(hostSettings)
        guard host.isRunning, case .server(let info)? = host.invite(host: "127.0.0.1") else { return }
        addServer(info, isLocalHost: true)
    }

    func stopHosting() async {
        for entry in servers where entry.isLocalHost { removeServer(entry.id) }
        await host.stop()
    }

    func rotateHostAccessKey() async {
        let wasRunning = host.isRunning
        if wasRunning { await stopHosting() }
        hostSettings.accessKey = Data.random(32)
        if wasRunning { await startHosting() }
    }

    // MARK: Retention & wipe

    var messageLifetimeHours: Int? {
        get { state?.messageLifetimeHours }
        set {
            state?.messageLifetimeHours = newValue
            purgeExpiredMessages()
            save()
        }
    }

    private func purgeExpiredMessages() {
        var changed = false
        for (id, sessions) in state?.sessions ?? [:] {
            var expired = sessions
            expired.expireSkippedKeys()
            if expired != sessions {
                state?.sessions[id] = expired
                changed = true
            }
        }
        if let hours = state?.messageLifetimeHours, let messages = state?.messages {
            let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
            for (ref, list) in messages {
                let kept = list.filter { $0.sentAt >= cutoff }
                if kept.count != list.count {
                    dropOutbox(of: list.filter { $0.sentAt < cutoff })
                    state?.messages[ref] = kept
                    changed = true
                }
            }
        }
        if changed { save() }
    }

    /// Destroys the identity and everything stored. Irreversible.
    func panicWipe() async {
        housekeeping?.cancel()
        discovery.stop()
        for id in Array(connections.keys) { disconnect(id) }
        await host.stop()
        saveTask?.cancel()
        receiptTask?.cancel()
        receiptTask = nil
        pendingReceipts = [:]
        Vault.wipe()
        state = nil
        identity = nil
        tagTargets = [:]
        keyCache = [:]
        phase = .onboarding
    }

    /// Writes immediately; used before ciphertext produced by a ratchet step leaves the device.
    private func saveNow() {
        saveTask?.cancel()
        if let state { try? Vault.save(state) }
    }

    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let state = self?.state else { return }
            try? Vault.save(state)
        }
    }
}
