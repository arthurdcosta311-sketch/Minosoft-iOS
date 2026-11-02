import SwiftUI

/// In-game shell: fullscreen Metal view, HUD on top, touch controls at the
/// bottom. All input goes through EngineBridge; all state arrives as immutable
/// WorldSnapshots, and the world itself is read straight off the engine by the
/// renderer.
struct GameView: View {
    let bridge: any EngineBridge
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot = WorldSnapshot.initial
    @State private var showDebug = false
    @State private var move = JoystickVector()

    var body: some View {
        ZStack {
            MetalWorldView(
                world: bridge.world,
                feetPosition: snapshot.playerPosition,
                yawDegrees: snapshot.playerYaw,
                pitchDegrees: snapshot.playerPitch
            )
            .ignoresSafeArea()

            VStack {
                HUDView(snapshot: snapshot, showDebug: showDebug)
                Spacer()
                TouchControls(
                    move: $move,
                    onLook: { delta in bridge.handle(.look(delta)) },
                    onPrimary: { bridge.handle(.primaryAction) },
                    onSecondary: { bridge.handle(.secondaryAction) }
                )
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showDebug.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                Button {
                    bridge.disconnect()
                    dismiss()
                } label: {
                    Image(systemName: "door.left.hand.open")
                }
                .accessibilityLabel("Leave server")
            }
        }
        .onChange(of: move) { _, vector in
            bridge.handle(.move(vector))
        }
        .task {
            for await snap in bridge.worldState {
                snapshot = snap
            }
        }
        .onDisappear {
            bridge.disconnect()
        }
    }
}
