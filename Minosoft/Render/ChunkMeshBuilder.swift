import Foundation

/// Nio's slice: one block vertex as the world shader wants it.
///
/// 32 bytes, all floats, no padding surprises: position, colour, light. The MSL
/// side uses the `packed_` types so the layouts match exactly and no vertex
/// descriptor is needed.
struct WorldVertex {
    var x: Float
    var y: Float
    var z: Float
    var r: Float
    var g: Float
    var b: Float
    var a: Float
    var light: Float
}

/// Turns one world section into triangles: only faces that touch a non-solid
/// neighbour are emitted, and every face is baked with the section's sky light
/// plus a per-direction shade, which is what makes terrain read as terrain.
enum ChunkMeshBuilder {
    struct Mesh {
        var vertices: [WorldVertex]
        var indices: [UInt32]
        var isEmpty: Bool { indices.isEmpty }
    }

    private struct Face {
        let normal: (Int, Int, Int)
        let shade: Float
        let corners: [(Float, Float, Float)]
    }

    /// Same winding order throughout; the renderer draws with culling off, so
    /// the order only has to be consistent, not clockwise-per-feature.
    private static let faces: [Face] = [
        // up (+y)
        Face(normal: (0, 1, 0), shade: 1.00,
             corners: [(0, 1, 0), (1, 1, 0), (1, 1, 1), (0, 1, 1)]),
        // down (-y)
        Face(normal: (0, -1, 0), shade: 0.55,
             corners: [(0, 0, 0), (0, 0, 1), (1, 0, 1), (1, 0, 0)]),
        // north (-z)
        Face(normal: (0, 0, -1), shade: 0.82,
             corners: [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)]),
        // south (+z)
        Face(normal: (0, 0, 1), shade: 0.82,
             corners: [(0, 0, 1), (0, 1, 1), (1, 1, 1), (1, 0, 1)]),
        // west (-x)
        Face(normal: (-1, 0, 0), shade: 0.68,
             corners: [(0, 0, 0), (0, 1, 0), (0, 1, 1), (0, 0, 1)]),
        // east (+x)
        Face(normal: (1, 0, 0), shade: 0.68,
             corners: [(1, 0, 0), (1, 0, 1), (1, 1, 1), (1, 1, 0)]),
    ]

    static func build(
        key: VoxelWorld.SectionKey,
        section: VoxelWorld.Section,
        sections: [VoxelWorld.SectionKey: VoxelWorld.Section]
    ) -> Mesh {
        var vertices: [WorldVertex] = []
        let blocks: [UInt16] = section.blocks
        var indices: [UInt32] = []

        // Reserve for the common case: a section that is mostly surface.
        vertices.reserveCapacity(1024)
        indices.reserveCapacity(1536)

        let originX = key.x << 4
        let originY = key.y << 4
        let originZ = key.z << 4
        let brightness = 0.25 + 0.75 * min(max(section.skyLight, 0), 1)

        for y in 0..<16 {
            for z in 0..<16 {
                for x in 0..<16 {
                    let index = (y << 8) | (z << 4) | x
                    let state = blocks[index]
                    if state == 0 { continue } // air

                    let worldX = originX + x
                    let worldY = originY + y
                    let worldZ = originZ + z
                    let colour = BlockPalette.colour(for: state)

                    for face in faces {
                        let neighbourState = stateAt(
                            worldX + face.normal.0,
                            worldY + face.normal.1,
                            worldZ + face.normal.2,
                            sections: sections
                        )
                        if neighbourState != 0 { continue } // hidden face

                        let base = UInt32(vertices.count)
                        let shade = face.shade
                        for corner in face.corners {
                            vertices.append(WorldVertex(
                                x: Float(worldX) + corner.0,
                                y: Float(worldY) + corner.1,
                                z: Float(worldZ) + corner.2,
                                r: colour.x * shade,
                                g: colour.y * shade,
                                b: colour.z * shade,
                                a: 1,
                                light: brightness
                            ))
                        }
                        indices.append(contentsOf: [base, base + 1, base + 2,
                                                    base, base + 2, base + 3])
                    }
                }
            }
        }

        return Mesh(vertices: vertices, indices: indices)
    }

    private static func stateAt(
        _ x: Int, _ y: Int, _ z: Int,
        sections: [VoxelWorld.SectionKey: VoxelWorld.Section]
    ) -> UInt16 {
        let key = VoxelWorld.SectionKey(x: x >> 4, y: y >> 4, z: z >> 4)
        // Unloaded neighbours count as air: the face is drawn, which is what you
        // want at the edge of the loaded world.
        guard let section = sections[key] else { return 0 }
        let index = ((y & 15) << 8) | ((z & 15) << 4) | (x & 15)
        return section.blocks[index]
    }
}

/// Placeholder block colours.
///
/// Vanilla's block registry (name → state ids → atlas UVs) is downloaded and
/// cached by Minosoft's asset pipeline; on iOS that pipeline is Pip's, and until
/// it lands the mesher colours blocks from their state id. Deterministic, stable
/// between runs, and immediately readable as terrain: everything stays in a
/// natural-material palette instead of random RGB.
enum BlockPalette {
    private static let palette: [SIMD3<Float>] = [
        SIMD3(0.36, 0.58, 0.28), // grass
        SIMD3(0.42, 0.32, 0.24), // dirt
        SIMD3(0.52, 0.52, 0.54), // stone
        SIMD3(0.62, 0.62, 0.64), // cobble / gravel
        SIMD3(0.22, 0.42, 0.24), // leaves
        SIMD3(0.50, 0.38, 0.22), // wood
        SIMD3(0.86, 0.80, 0.58), // sand
        SIMD3(0.30, 0.36, 0.52), // water
        SIMD3(0.94, 0.94, 0.88), // snow
        SIMD3(0.68, 0.28, 0.22), // brick / nether
        SIMD3(0.30, 0.28, 0.34), // deepslate
        SIMD3(0.76, 0.70, 0.36), // sandstone
        SIMD3(0.20, 0.30, 0.44), // dark water
        SIMD3(0.48, 0.44, 0.40), // andesite
        SIMD3(0.58, 0.50, 0.30), // oak planks
        SIMD3(0.34, 0.46, 0.36), // mossy
    ]

    static func colour(for state: UInt16) -> SIMD3<Float> {
        var hash = UInt32(truncatingIfNeeded: Int(state) &* 2654435761)
        hash = (hash >> 13) ^ hash
        return palette[Int(hash % UInt32(palette.count))]
    }
}
