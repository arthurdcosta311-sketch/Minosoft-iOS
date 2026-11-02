import Foundation
import MetalKit
import simd

/// Nio's slice: the world pass. Draws every meshed section through one pipeline:
/// camera → view/projection → per-section vertex/index buffers → drawIndexed.
///
/// Meshing happens lazily here, driven by the world's dirty set, so a chunk that
/// arrives over the network only costs its own section rebuilds.
final class WorldSceneRenderer: NSObject, MTKViewDelegate {
    /// Must match `WorldUniforms` in WorldShaders.metal field for field.
    private struct WorldUniforms {
        var viewProjection: simd_float4x4
        var cameraPosition: SIMD4<Float>
        var fogColour: SIMD4<Float>
        var fogRange: SIMD2<Float>
    }

    private struct DrawMesh {
        var vertexBuffer: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let world: VoxelWorld

    private var meshes: [VoxelWorld.SectionKey: DrawMesh] = [:]
    private var builtInitialSections = false

    private let cameraLock = NSLock()
    private var cameraFeet = SIMD3<Float>(0, 48, 0)
    private var cameraYaw: Float = 0
    private var cameraPitch: Float = 0

    private static let eyeHeight: Float = 1.62
    private static let fogColour = SIMD4<Float>(0.47, 0.71, 0.99, 1)

    init?(view: MTKView, world: VoxelWorld) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "world_vertex"),
              let fragmentFunction = library.makeFunction(name: "world_fragment")
        else { return nil }

        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.47, green: 0.71, blue: 0.99, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.depthState = depthState
        self.world = world
        super.init()

        view.delegate = self
    }

    func update(cameraPosition: SIMD3<Float>, yaw: Float, pitch: Float) {
        cameraLock.lock()
        cameraFeet = cameraPosition
        cameraYaw = yaw
        cameraPitch = pitch
        cameraLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: Drawing

    func draw(in view: MTKView) {
        refreshMeshes()

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        cameraLock.lock()
        let feet = cameraFeet
        let yawDegrees = cameraYaw
        let pitchDegrees = cameraPitch
        cameraLock.unlock()
        // The engine speaks degrees (Minecraft convention); the matrix code here
        // works in radians.
        let yaw = yawDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180

        let eye = feet + SIMD3<Float>(0, Self.eyeHeight, 0)
        let size = view.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        let projection = WorldCameraMatrices.projection(
            fovY: 70 * .pi / 180,
            aspect: max(aspect, 0.1),
            near: 0.05,
            far: 512
        )
        let viewMatrix = WorldCameraMatrices.view(position: eye, yaw: yaw, pitch: pitch)

        var uniforms = WorldUniforms(
            viewProjection: projection * viewMatrix,
            cameraPosition: SIMD4<Float>(eye.x, eye.y, eye.z, 1),
            fogColour: Self.fogColour,
            fogRange: SIMD2<Float>(96, 160)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)

        for mesh in meshes.values {
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: .uint32,
                indexBuffer: mesh.indexBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Meshing

    private func refreshMeshes() {
        let changes = world.takeChanges()
        for key in changes.removed {
            meshes.removeValue(forKey: key)
        }

        var toBuild = changes.dirty
        if !builtInitialSections {
            builtInitialSections = true
            world.withSections { sections in
                toBuild.formUnion(sections.keys)
            }
        }
        guard !toBuild.isEmpty else { return }

        world.withSections { sections in
            for key in toBuild {
                guard let section = sections[key] else {
                    meshes.removeValue(forKey: key)
                    continue
                }
                let built = ChunkMeshBuilder.build(key: key, section: section, sections: sections)
                guard !built.vertices.isEmpty, !built.indices.isEmpty else {
                    meshes.removeValue(forKey: key)
                    continue
                }
                meshes[key] = makeMesh(built)
            }
        }
    }

    private func makeMesh(_ built: ChunkMeshBuilder.Mesh) -> DrawMesh? {
        let vertexBytes = built.vertices.count * MemoryLayout<WorldVertex>.stride
        let indexBytes = built.indices.count * MemoryLayout<UInt32>.stride

        guard let vertexBuffer = device.makeBuffer(bytes: built.vertices, length: vertexBytes,
                                                   options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: built.indices, length: indexBytes,
                                                  options: .storageModeShared)
        else { return nil }

        return DrawMesh(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: built.indices.count
        )
    }
}

/// Right-handed camera, Metal's [0, 1] depth range. Kept local to the world pass;
/// `Render/Camera.swift` holds the engine-facing pose the session feeds.
enum WorldCameraMatrices {
    static func projection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }

    /// Minecraft's yaw convention: 0 looks down -Z, increasing yaw turns right.
    static func view(position: SIMD3<Float>, yaw: Float, pitch: Float) -> simd_float4x4 {
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)

        let forward = simd_normalize(SIMD3<Float>(sinYaw * cosPitch, sinPitch, -cosYaw * cosPitch))
        let target = position + forward
        let up = SIMD3<Float>(0, 1, 0)

        let f = simd_normalize(target - position)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)

        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, position), -simd_dot(u, position), simd_dot(f, position), 1)
        ))
    }
}
