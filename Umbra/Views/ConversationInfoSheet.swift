import SwiftUI
import UmbraCore

struct ConversationInfoSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let ref: ConversationRef
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                switch ref {
                case .room(let id):
                    if let room = model.room(id) { roomSection(room) }
                case .direct(let id):
                    if let contact = model.contact(id) { contactSection(contact) }
                }
                Section {
                    Button("Clear messages on this device") { model.clearMessages(in: ref) }
                    Button(isRoom ? "Leave room" : "Delete contact", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.title(for: ref))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("This removes it and its messages from this device.", isPresented: $confirmDelete) {
                Button(isRoom ? "Leave room" : "Delete contact", role: .destructive) {
                    model.delete(ref)
                    dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private var isRoom: Bool { if case .room = ref { true } else { false } }

    @ViewBuilder private func roomSection(_ room: Room) -> some View {
        Section {
            InviteCard(
                title: "Room code", link: room.invite.url,
                warning: "Anyone with this code can read and post in the room. Share in person or over an encrypted chat.")
        }
        if !model.contacts.isEmpty {
            Section("Send invite over encrypted DM") {
                ForEach(model.contacts) { contact in
                    Button(contact.identity.name, systemImage: "paperplane") {
                        model.send(room.invite.url, to: .direct(contactID: contact.id))
                    }
                }
            }
        }
    }

    @ViewBuilder private func contactSection(_ contact: Contact) -> some View {
        Section {
            LabeledContent("Fingerprint") {
                Text(contact.identity.fingerprint).font(.body.monospaced())
            }
            Toggle("Verified in person", isOn: .init(
                get: { contact.verified }, set: { model.setVerified(contact.id, $0) }))
        } footer: {
            Text("Compare this fingerprint with the one on \(contact.identity.name)'s Me tab. If they match, nobody is impersonating them.")
        }
    }
}
