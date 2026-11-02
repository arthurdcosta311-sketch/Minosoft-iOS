import SwiftUI

struct ContentView: View {
    @StateObject private var store = ServerStore()
    @AppStorage("minosoft.playerName") private var playerName = ""
    @ObservedObject private var accounts = AccountStore.shared
    @State private var showingAddServer = false
    @State private var showingAccount = false
    @State private var showingPortStatus = false
    @State private var refreshID = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if store.servers.isEmpty {
                    ContentUnavailableView {
                        Label("No servers yet", systemImage: "server.rack")
                    } description: {
                        Text("Add a Minecraft server to check its live status.")
                    } actions: {
                        Button("Add Server") { showingAddServer = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.servers) { server in
                                ServerRow(server: server, account: joinAccount, refreshID: refreshID) {
                                    store.delete(server)
                                }
                            }
                            .onDelete { store.delete(atOffsets: $0) }
                        } footer: {
                            Text("Status checks, 1.20.4 login (offline mode or a Microsoft account), live chunk decoding, Metal rendering and chat are working. Registries, textures and original Minosoft physics are still being ported.")
                        }
                    }
                    .refreshable {
                        refreshID = UUID()
                    }
                }
            }
            .navigationTitle("Minosoft")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingPortStatus = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About the iOS port")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingAccount = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Player: \(joinAccount.username)")

                    Button {
                        showingAddServer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add server")
                }
            }
            .sheet(isPresented: $showingAddServer) {
                AddServerView { store.add($0) }
            }
            .sheet(isPresented: $showingAccount) {
                PlayerSettingsView()
            }
            .sheet(isPresented: $showingPortStatus) {
                PortStatusView()
            }
        }
    }

    /// Who a server sees: the signed-in Minecraft profile when there is one,
    /// otherwise the local offline name.
    private var joinAccount: Account {
        if let signedIn = accounts.signedIn {
            return Account.microsoft(signedIn)
        }
        return Account(username: playerName.isEmpty ? "Player" : playerName, kind: .offline)
    }
}

private struct ServerRow: View {
    let server: MinecraftServer
    let account: Account
    let refreshID: UUID
    let onDelete: () -> Void
    @StateObject private var ping = ServerPingState()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ping.status == nil ? "server.rack" : "checkmark.circle.fill")
                .foregroundStyle(ping.status == nil ? Color.secondary : Color.green)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                Text("\(server.host):\(server.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                statusLine
            }

            Spacer(minLength: 8)

            Button {
                Task { await ping.ping(server) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(ping.isPinging)
            .accessibilityLabel("Ping \(server.name)")

            NavigationLink {
                ConnectView(
                    server: ServerEntry(
                        name: server.name,
                        address: ServerAddress(host: server.host, port: Int(server.port))
                    ),
                    account: account
                )
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Join \(server.name)")

            Menu {
                Button("Refresh status", systemImage: "arrow.clockwise") {
                    Task { await ping.ping(server) }
                }
                Button("Remove Server", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Server options for \(server.name)")
        }
        .padding(.vertical, 4)
        .task(id: refreshID) {
            await ping.ping(server)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if ping.isPinging {
            Label("Checking server…", systemImage: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let status = ping.status {
            let latency = status.latencyMs.map { " · \($0) ms" } ?? ""
            Text("\(status.motd) · \(status.playersOnline)/\(status.playersMax) · \(status.versionName)\(latency)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else if let errorText = ping.errorText {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else {
            Text("Not checked")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct AddServerView: View {
    let onAdd: (MinecraftServer) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "25565"
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addServer() }
                        .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func addServer() {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedPort = UInt16(port), parsedPort > 0 else {
            validationMessage = "Enter a port from 1 to 65535."
            return
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = MinecraftServer(
            name: cleanName.isEmpty ? cleanHost : cleanName,
            host: cleanHost,
            port: parsedPort
        )
        guard onAdd(server) else {
            validationMessage = "That server is already saved."
            return
        }
        dismiss()
    }
}

private struct PlayerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("minosoft.playerName") private var playerName = ""
    @ObservedObject private var accounts = AccountStore.shared

    @State private var showingSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let signedIn = accounts.signedIn {
                        LabeledContent("Name", value: signedIn.name)
                        LabeledContent("Profile", value: signedIn.uuid.uuidString.lowercased())
                            .font(.caption)
                        Button("Sign out", role: .destructive) {
                            accounts.signOut()
                        }
                    } else {
                        Button {
                            showingSignIn = true
                        } label: {
                            Label("Sign in with Microsoft", systemImage: "person.badge.key")
                        }
                    }
                } header: {
                    Text("Microsoft account")
                } footer: {
                    Text(accounts.signedIn == nil
                         ? "Online-mode servers verify your Minecraft profile with Microsoft. You confirm a short code in your browser, so the app never sees your password."
                         : "Online-mode servers now verify this profile when you join.")
                }

                Section {
                    TextField("Username", text: $playerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Offline player name")
                } footer: {
                    Text("Used only for offline-mode servers, and saved on this device.")
                }
            }
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSignIn) {
                MicrosoftSignInView()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct PortStatusView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Available now") {
                    Label("Add and save server addresses on this device", systemImage: "checkmark.circle")
                    Label("Query Minecraft server status and latency", systemImage: "checkmark.circle")
                    Label("Microsoft sign-in and online-mode encryption", systemImage: "checkmark.circle")
                    Label("Offline-mode login, chat, and movement for 1.20.4", systemImage: "checkmark.circle")
                    Label("Live chunk decoding and Metal world rendering", systemImage: "checkmark.circle")
                }
                Section("Still being ported") {
                    Text("Full block/entity registries and textures, original Minosoft physics, and the rest of gameplay are still incomplete.")
                }
            }
            .navigationTitle("iOS port status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
