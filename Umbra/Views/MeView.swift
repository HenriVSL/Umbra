import SwiftUI
import UmbraCore

struct MeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack {
            Form {
                if let identity = model.identity, let invite = model.myInvite() {
                    Section {
                        InviteCard(title: identity.name, link: invite.url)
                        LabeledContent("Fingerprint") {
                            Text(identity.publicIdentity.fingerprint).font(.body.monospaced())
                        }
                    } footer: {
                        Text("Your public code is safe to show. When someone scans it, they are added as a contact and you get a contact request from them.")
                    }
                }
                Section {
                    Picker("Auto-delete messages", selection: .init(
                        get: { model.messageLifetimeHours ?? 0 },
                        set: { model.messageLifetimeHours = $0 == 0 ? nil : $0 })) {
                        Text("Never").tag(0)
                        Text("After 1 hour").tag(1)
                        Text("After 24 hours").tag(24)
                        Text("After 7 days").tag(168)
                        Text("After 30 days").tag(720)
                    }
                } footer: {
                    Text("Applies to messages stored on this device. All local data is encrypted with a key held in this device's Keychain.")
                }
                Section {
                    Button("Wipe everything", systemImage: "flame", role: .destructive) { confirmWipe = true }
                } footer: {
                    Text("Destroys your identity, contacts, rooms and messages on this device. Cannot be undone.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Me")
            .confirmationDialog("Wipe all Umbra data on this device?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Wipe now", role: .destructive) { Task { await model.panicWipe() } }
            }
        }
    }
}
