import SwiftUI
import UmbraCore

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    let ref: ConversationRef
    @State private var draft = ""
    @State private var showInfo = false
    @State private var notice: String?

    var body: some View {
        let messages = model.messages(in: ref)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message, showSender: isRoom, onNotice: { notice = $0 })
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onAppear { if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChangeOf(messages.count) { _ in
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(model.title(for: ref))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Info", systemImage: isRoom ? "qrcode" : "info.circle") { showInfo = true }
            }
        }
        .sheet(isPresented: $showInfo) { ConversationInfoSheet(ref: ref) }
        .alert(notice ?? "", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {}
    }

    private var isRoom: Bool { if case .room = ref { true } else { false } }

    private var composer: some View {
        HStack(spacing: 8) {
            if model.onlineCount == 0 {
                Image(systemName: "wifi.slash").foregroundStyle(.orange).help("No server online — messages are queued")
            }
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(send)
            Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .font(.title2)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        model.send(draft, to: ref)
        draft = ""
    }
}

struct MessageBubble: View {
    @EnvironmentObject private var model: AppModel
    let message: ChatMessage
    let showSender: Bool
    let onNotice: (String) -> Void

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                if showSender && !message.isOutgoing {
                    let label = model.senderLabel(for: message)
                    HStack(spacing: 3) {
                        Text(label.name)
                        if label.trusted { Image(systemName: "checkmark.seal.fill") }
                    }
                    .font(.caption.bold())
                    .foregroundStyle(label.trusted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isOutgoing ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(Color.gray.opacity(0.18)),
                                in: .rect(cornerRadius: 14))
                HStack(spacing: 4) {
                    Text(message.sentAt, style: .time)
                    if message.isOutgoing { statusIcon }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if message.status == .unheard {
                    Button("Nobody was listening — resend", systemImage: "arrow.clockwise") { model.retry(message) }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                }
            }
            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(message.text) }
            if model.canAddContact(from: message) {
                Button("Add \(message.senderName) as contact", systemImage: "person.badge.plus") {
                    model.addContact(fromMessage: message)
                    onNotice("Contact request sent to \(message.senderName)")
                }
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch message.status {
        case .pending: Image(systemName: "clock")
        case .sent: Image(systemName: "checkmark")
        case .delivered: Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        case .unheard: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .received: EmptyView()
        }
    }

    /// Umbra links sent in a chat render as a card that can be joined/added with one tap.
    @ViewBuilder private var content: some View {
        if let invite = try? Invite(url: message.text) {
            VStack(alignment: .leading, spacing: 6) {
                Label(invite.summary, systemImage: invite.symbol).font(.subheadline.bold())
                Button(invite.actionTitle) {
                    onNotice((try? model.importInvite(message.text)) ?? "Invalid code")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else {
            Text(message.text).textSelection(.enabled)
        }
    }
}

extension Invite {
    var summary: String {
        switch self {
        case .contact(let p): "Contact: \(p.name)"
        case .room(let name, _): "Room: \(name)"
        case .server(let s): "Server: \(s.name.isEmpty ? s.host : s.name)"
        }
    }

    var symbol: String {
        switch self {
        case .contact: "person.crop.circle.badge.plus"
        case .room: "person.3"
        case .server: "server.rack"
        }
    }

    var actionTitle: String {
        switch self {
        case .contact: "Add contact"
        case .room: "Join room"
        case .server: "Add server"
        }
    }
}
