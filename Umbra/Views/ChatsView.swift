import SwiftUI
import UmbraCore

struct ChatsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showScanner = false
    @State private var showNewRoom = false
    @State private var path: [ConversationRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.servers.isEmpty {
                    Section {
                        Label("Add or host a server to start chatting.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if !model.requests.isEmpty {
                    Section("Contact requests") {
                        ForEach(model.requests) { request in RequestRow(request: request) }
                    }
                }
                Section {
                    ForEach(model.conversations, id: \.self) { ref in
                        NavigationLink(value: ref) { ConversationRow(ref: ref) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { model.delete(ref) }
                            }
                    }
                } footer: {
                    if model.conversations.isEmpty {
                        Text("Scan a contact's code to message them, or create a room and share its code.")
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: ConversationRef.self) { ChatView(ref: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Scan or paste code", systemImage: "qrcode.viewfinder") { showScanner = true }
                        Button("New room", systemImage: "person.3") { showNewRoom = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showScanner) { ScanSheet() }
            .sheet(isPresented: $showNewRoom) {
                NewRoomSheet { room in path.append(.room(roomID: room.id)) }
            }
        }
    }
}

struct ConversationRow: View {
    @EnvironmentObject private var model: AppModel
    let ref: ConversationRef

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title(for: ref)).font(.headline)
                if let last = model.lastMessage(in: ref) {
                    Text(last.text).lineLimit(1).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let last = model.lastMessage(in: ref) {
                Text(last.sentAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch ref {
        case .room: "person.3.fill"
        case .direct(let id): model.contact(id)?.verified == true ? "person.fill.checkmark" : "person.fill"
        }
    }
}

struct RequestRow: View {
    @EnvironmentObject private var model: AppModel
    let request: ContactRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.identity.name).font(.headline)
            Text(request.identity.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Button("Accept") { model.accept(request) }.buttonStyle(.borderedProminent)
                Button("Ignore", role: .destructive) { model.ignore(request) }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NewRoomSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onCreate: (Room) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Room name", text: $name)
                Text("A new random room key is created. Everyone you share the room code with can read and post.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("New room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let room = model.createRoom(named: name)
                        dismiss()
                        onCreate(room)
                    }
                }
            }
        }
    }
}
