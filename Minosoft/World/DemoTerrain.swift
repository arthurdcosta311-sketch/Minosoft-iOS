import Foundation

/// A small deterministic world so the renderer has real geometry to draw before
/// a session delivers chunks. It goes through exactly the same path as network
/// chunks — decoded sections into `VoxelWorld` — so it doubles as a renderer
/// smoke test.
extension VoxelWorld {
    static func demo() -> VoxelWorld {
        let world = VoxelWorld()
        let radius = 3
        let sectionCount = 8 // 8 × 16 blocks: y = -64 ... 63

        for chunkX in -radius...radius {
            for chunkZ in -radius...radius {
                var sections: [ChunkDecoder.DecodedSection] = []
                sections.reserveCapacity(sectionCount)

                for sectionIndex in 0..<sectionCount {
                    var blocks = [UInt16](repeating: 0, count: 4096)
                    for y in 0..<16 {
                        let worldY = (world.minSection + sectionIndex) * 16 + y
                        for z in 0..<16 {
                            for x in 0..<16 {
                                let worldX = chunkX * 16 + x
                                let worldZ = chunkZ * 16 + z
                                let height = terrainHeight(worldX, worldZ)
                                guard worldY <= height else { continue }
                                let depth = height - worldY
                                let state: UInt16
                                if depth == 0 {
                                    state = 3 // grass
                                } else if depth < 4 {
                                    state = 2 // dirt
                                } else {
                                    state = 4 // stone
                                }
                                blocks[(y << 8) | (z << 4) | x] = UInt16((height &* 7) &+ depth &+ 3) &+ state
                            }
                        }
                    }
                    sections.append(ChunkDecoder.DecodedSection(blocks: blocks, skyLight: 1))
                }

                world.insert(chunkX: chunkX, chunkZ: chunkZ, sections: sections)
            }
        }
        return world
    }

    private static func terrainHeight(_ x: Int, _ z: Int) -> Int {
        let a = sin(Double(x) * 0.08) * 4
        let b = cos(Double(z) * 0.11) * 3
        let c = sin(Double(x + z) * 0.03) * 5
        return Int(20 + a + b + c)
    }
}
