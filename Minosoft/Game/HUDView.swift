import SwiftUI

/// In-game HUD: the F3-style debug panel behind a toggle, a connection status
/// bubble while the session is coming up, and the last chat lines.
struct HUDView: View {
    var snapshot: WorldSnapshot
    var showDebug: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showDebug {
                debugPanel
            }
            if let statusText {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(statusText)
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            Spacer(minLength: 0)

            chatPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .allowsHitTesting(false)
    }

    private var statusText: String? {
        switch snapshot.state {
        case .connecting: return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .loggingIn: return "Logging in…"
        case .playing, .disconnected: return nil
        }
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Minosoft iOS")
            Text(snapshot.debugMessage)
            Text("tick \(snapshot.tick)")
            Text(String(
                format: "xyz %.1f / %.1f / %.1f",
                snapshot.playerPosition.x,
                snapshot.playerPosition.y,
                snapshot.playerPosition.z
            ))
            Text("sections \(snapshot.loadedChunkCount)")
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var chatPanel: some View {
        let lines = Array(snapshot.chatLines.suffix(6))
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                }
            }
            .padding(8)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
