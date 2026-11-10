import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .ready:
                TabView {
                    ChatsView()
                        .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                        .badge(model.requests.count)
                    ServersView()
                        .tabItem { Label("Servers", systemImage: "antenna.radiowaves.left.and.right") }
                        .badge(model.host.isRunning ? Text("ON") : nil)
                    MeView()
                        .tabItem { Label("Me", systemImage: "person.crop.square") }
                }
            case .onboarding:
                OnboardingView()
            case .locked(let reason):
                LockedVaultView(reason: reason)
            }
        }
        .onChangeOf(scenePhase) { phase in
            switch phase {
            case .background: model.didEnterBackground()
            case .active: Task { await model.didBecomeActive() }
            default: break
            }
        }
    }
}

struct LockedVaultView: View {
    @EnvironmentObject private var model: AppModel
    let reason: String
    @State private var confirmErase = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.trianglebadge.exclamationmark").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Vault can't be opened").font(.title2.bold())
            Text(reason + "\nYour identity and messages are still on this device but can't be read right now.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again") { model.retryUnlock() }.buttonStyle(.borderedProminent)
            Button("Erase and start over", role: .destructive) { confirmErase = true }
        }
        .padding()
        .confirmationDialog("Erase the unreadable vault? Your identity cannot be recovered.", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { model.eraseUnreadableVault() }
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Umbra").font(.largeTitle.bold())
            Text("End-to-end encrypted chat over servers you control.\nKeys are generated on this device and never leave it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("Callsign", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit(create)
            Button("Create identity", action: create)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding()
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.createIdentity(name: name)
    }
}
