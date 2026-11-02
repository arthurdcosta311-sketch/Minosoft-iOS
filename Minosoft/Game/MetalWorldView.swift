import SwiftUI
import MetalKit

/// Nio + Pip's seam: the SwiftUI shell hosting the world pass.
///
/// The renderer owns meshing and drawing; this view only forwards the camera and
/// swaps the renderer when a new session brings a new world. With no session yet
/// it draws the demo terrain, so the renderer can be checked without a server.
struct MetalWorldView: UIViewRepresentable {
    /// The live block world from the session, or nil before one exists.
    var world: VoxelWorld?
    /// Where the player's feet are.
    var feetPosition: SIMD3<Float>
    /// Minecraft yaw in degrees (0 looks towards -Z).
    var yawDegrees: Float
    /// Minecraft pitch in degrees (positive looks up).
    var pitchDegrees: Float

    @MainActor
    final class Coordinator {
        var renderer: WorldSceneRenderer?
        var world: VoxelWorld?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        install(into: view, context: context)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // A new session hands us a new world: rebuild against it.
        if let world, context.coordinator.world !== world {
            install(into: uiView, context: context)
        }

        context.coordinator.renderer?.update(
            cameraPosition: feetPosition,
            yaw: yawDegrees,
            pitch: pitchDegrees
        )
    }

    private func install(into view: MTKView, context: Context) {
        let world = self.world ?? VoxelWorld.demo()
        context.coordinator.world = world

        if let renderer = WorldSceneRenderer(view: view, world: world) {
            context.coordinator.renderer = renderer
        }
    }
}
