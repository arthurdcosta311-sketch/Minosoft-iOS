import SwiftUI

/// Starts a real Minecraft 1.20.4 login session — offline, or online mode
/// backed by the signed-in Microsoft account.
struct ConnectView: View {
    let server: ServerEntry
    let account: Account

    @State private var bridge: (any EngineBridge)?
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView(
                    "Could not connect",
                    systemImage: "wifi.exclamationmark",
                    description: Text(failure)
                )
            } else if let bridge {
                GameView(bridge: bridge)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to \(server.name)…")
                        .foregroundStyle(.secondary)
                }
                .navigationTitle(server.name)
            }
        }
        .task {
            let engine = RealEngineBridge()
            do {
                try await engine.connect(to: server.address, account: account)
                bridge = engine
            } catch {
                engine.disconnect()
                failure = error.localizedDescription
            }
        }
        .onDisappear {
            bridge?.disconnect()
        }
    }
}
