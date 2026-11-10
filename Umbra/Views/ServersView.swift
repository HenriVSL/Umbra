import SwiftUI
import UmbraCore

struct ServersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.servers) { entry in ServerRow(entry: entry) }
                        .onDelete { offsets in
                            for i in offsets { model.removeServer(model.servers[i].id) }
                        }
                    Button("Add server by code", systemImage: "qrcode.viewfinder") { showScanner = true }
                } header: {
                    Text("Connected servers")
                } footer: {
                    Text("Messages go out through every online server and arrive from any of them. Servers only see opaque, rotating routing tags and ciphertext.")
                }
                HostSection()
            }
            .navigationTitle("Servers")
            .sheet(isPresented: $showScanner) { ScanSheet() }
        }
    }
}

struct ServerRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: ServerEntry

    var body: some View {
        let status = model.status(of: entry.id)
        HStack {
            Circle().fill(color(status)).frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(entry.isLocalHost ? "This device" : (entry.info.name.isEmpty ? entry.info.host : entry.info.name))
                    .font(.headline)
                Text("\(entry.info.host):\(entry.info.port) · \(describe(status))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !entry.isLocalHost {
                Toggle("Enabled", isOn: .init(get: { entry.enabled }, set: { model.setEnabled(entry.id, $0) }))
                    .labelsHidden()
            }
        }
    }

    private func color(_ s: ServerConnection.Status) -> Color {
        switch s {
        case .online: .green
        case .connecting: .yellow
        case .rejected: .red
        case .offline: .gray
        }
    }

    private func describe(_ s: ServerConnection.Status) -> String {
        switch s {
        case .online(let mode, let retention):
            mode == .store ? "online · stores \(Int(retention / 3600))h" : "online · relay only"
        case .connecting: "connecting"
        case .rejected: "access denied"
        case .offline(let why): why.lowercased()
        }
    }
}

struct HostSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedAddress: String?
    @State private var busy = false

    var body: some View {
        let host = model.host
        Section {
            Toggle("Host a server on this device", isOn: .init(
                get: { host.isRunning },
                set: { on in
                    busy = true
                    Task {
                        if on { await model.startHosting() } else { await model.stopHosting() }
                        busy = false
                    }
                }))
            .disabled(busy)

            if host.isRunning {
                LabeledContent("Status") {
                    Text("\(host.connectionCount) connected · port \(host.boundPort ?? 0)").monospacedDigit()
                }
                #if os(iOS)
                Label("Keep Umbra open on screen. Auto-lock is disabled while hosting; switching apps for more than ~30 s pauses the server.", systemImage: "iphone.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                #endif
            }

            Picker("Mode", selection: $model.hostSettings.mode) {
                Text("Store & forward").tag(ServerMode.store)
                Text("Relay only").tag(ServerMode.relay)
            }
            .disabled(host.isRunning)
            if model.hostSettings.mode == .store {
                Stepper("Keep for \(model.hostSettings.retentionHours) h", value: $model.hostSettings.retentionHours, in: 1...720)
                    .disabled(host.isRunning)
                Stepper("Memory cap \(model.hostSettings.maxStoreMB) MB", value: $model.hostSettings.maxStoreMB, in: 16...1024, step: 16)
                    .disabled(host.isRunning)
            }
            Toggle("Announce on local network", isOn: $model.hostSettings.announce)
                .disabled(host.isRunning)
            Toggle("Start when app opens", isOn: $model.hostSettings.autoStart)

            if let error = host.error { Text(error).foregroundStyle(.red) }

            if host.isRunning {
                if host.addresses.isEmpty {
                    Text("No network address found. Join the team Wi-Fi or connect to the field router.").foregroundStyle(.orange)
                } else {
                    Picker("Address for code", selection: .init(
                        get: { selectedAddress.flatMap { host.addresses.contains($0) ? $0 : nil } ?? host.addresses[0] },
                        set: { selectedAddress = $0 })) {
                        ForEach(host.addresses, id: \.self) { Text($0).tag($0) }
                    }
                    let address = selectedAddress.flatMap { host.addresses.contains($0) ? $0 : nil } ?? host.addresses[0]
                    if let invite = host.invite(host: address) {
                        InviteCard(
                            title: "Server code", link: invite.url,
                            warning: "Grants use of this server. Rotate the access key to revoke everyone.")
                    }
                }
                Button("Rotate access key", role: .destructive) { Task { await model.rotateHostAccessKey() } }
            }
        } header: {
            Text("Hosting")
        } footer: {
            Text("Store & forward holds encrypted messages for people who are offline, in memory and in an encrypted file on this device. With announcing on, clients that scanned this code follow the server if its IP address changes. A computer running umbra-server is the better choice when one is available.")
        }
    }
}
