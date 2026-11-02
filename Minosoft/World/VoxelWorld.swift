import Foundation

/// Sable's slice: the client's block storage.
///
/// One section per 16×16×16 cube, keyed by its section coordinate, so chunks can
/// arrive, update and unload in any order and neighbours can be looked up across
/// chunk borders without juggling column arrays. Every access takes the lock;
/// the renderer copies what it needs while holding it.
final class VoxelWorld {
    struct SectionKey: Hashable {
        var x: Int
        var y: Int
        var z: Int
    }

    struct Section {
        var blocks: [UInt16]
        var skyLight: Float
    }

    private let lock = NSLock()
    private var sections: [SectionKey: Section] = [:]
    private var dirty: Set<SectionKey> = []
    private var removed: Set<SectionKey> = []
    private var generationCount = 0

    /// Bottom of the current dimension. The overworld starts at -64 in 1.20.4.
    private(set) var minY: Int = -64
    private(set) var minSection: Int = -4
    private(set) var sectionCount: Int = 24

    var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return generationCount
    }

    var loadedSectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sections.count
    }

    func configure(minY: Int, height: Int) {
        guard minY.isMultiple(of: 16), height > 0, height.isMultiple(of: 16) else { return }
        lock.lock(); defer { lock.unlock() }
        self.minY = minY
        self.minSection = minY / 16
        self.sectionCount = height / 16
    }

    // MARK: Mutating

    func insert(chunkX: Int, chunkZ: Int, sections newSections: [ChunkDecoder.DecodedSection]) {
        lock.lock(); defer { lock.unlock() }
        for (index, decoded) in newSections.enumerated() {
            let key = SectionKey(x: chunkX, y: minSection + index, z: chunkZ)
            sections[key] = Section(blocks: decoded.blocks, skyLight: decoded.skyLight)
            dirty.insert(key)
        }
        generationCount += 1
    }

    func light(chunkX: Int, chunkZ: Int, skyLight: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for (index, value) in skyLight.enumerated() {
            let key = SectionKey(x: chunkX, y: minSection + index, z: chunkZ)
            guard var section = sections[key] else { continue }
            section.skyLight = value
            sections[key] = section
            dirty.insert(key)
        }
    }

    func removeChunk(x: Int, z: Int) {
        lock.lock(); defer { lock.unlock() }
        for key in sections.keys where key.x == x && key.z == z {
            sections.removeValue(forKey: key)
            dirty.remove(key)
            removed.insert(key)
        }
        generationCount += 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        removed.formUnion(sections.keys)
        sections.removeAll()
        dirty.removeAll()
        generationCount += 1
    }

    func setBlock(state: UInt16, x: Int, y: Int, z: Int) {
        lock.lock(); defer { lock.unlock() }
        let key = SectionKey(x: x >> 4, y: y >> 4, z: z >> 4)
        guard var section = sections[key] else { return }
        let index = ((y & 15) << 8) | ((z & 15) << 4) | (x & 15)
        section.blocks[index] = state
        sections[key] = section
        dirty.insert(key)
        // A block on a section edge also changes the neighbour's culling.
        if (y & 15) == 0 { dirty.insert(SectionKey(x: key.x, y: key.y - 1, z: key.z)) }
        if (y & 15) == 15 { dirty.insert(SectionKey(x: key.x, y: key.y + 1, z: key.z)) }
        generationCount += 1
    }

    // MARK: Reading

    /// Block state at a world position; 0 is air in the flattened registries.
    func blockState(x: Int, y: Int, z: Int) -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        return unlockedState(x, y, z)
    }

    func isSolid(x: Int, y: Int, z: Int) -> Bool {
        blockState(x: x, y: y, z: z) != 0
    }

    /// Meshing needs consistent reads of a whole section plus its neighbours, so
    /// it runs inside one lock rather than per block.
    func withSections<T>(_ body: ([SectionKey: Section]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(sections)
    }

    func takeChanges() -> (dirty: Set<SectionKey>, removed: Set<SectionKey>) {
        lock.lock(); defer { lock.unlock() }
        let result = (dirty, removed)
        dirty.removeAll()
        removed.removeAll()
        return result
    }

    func unlakedState(_ x: Int, _ y: Int, _ z: Int) -> UInt16 { unlockedState(x, y, z) }

    private func unlockedState(_ x: Int, _ y: Int, _ z: Int) -> UInt16 {
        let key = SectionKey(x: x >> 4, y: y >> 4, z: z >> 4)
        guard let section = sections[key] else { return 0 }
        let index = ((y & 15) << 8) | ((z & 15) << 4) | (x & 15)
        return section.blocks[index]
    }

    // MARK: Raycast

    struct Hit {
        var x: Int
        var y: Int
        var z: Int
        var face: Int
        var state: UInt16
    }

    /// Walks a ray through the voxel grid, returning the first non-air block and
    /// which of its faces the ray entered through.
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float = 5) -> Hit? {
        var previous: (Int, Int, Int)?
        var travelled: Float = 0
        let step: Float = 0.05

        while travelled <= maxDistance {
            let point = origin + direction * travelled
            let cell = (Int(floor(point.x)), Int(floor(point.y)), Int(floor(point.z)))

            if let last = previous, last != cell {
                let state = blockState(x: cell.0, y: cell.1, z: cell.2)
                if state != 0 {
                    return Hit(x: cell.0, y: cell.1, z: cell.2,
                               face: face(from: last, to: cell), state: state)
                }
                if travelled > step * 2 && abs(cell.0 - last.0) + abs(cell.1 - last.1) + abs(cell.2 - last.2) > 1 {
                    return nil // diagonal jump, nothing between: stop instead of tunnelling
                }
            }
            previous = cell
            travelled += step
        }
        return nil
    }

    private func face(from last: (Int, Int, Int), to cell: (Int, Int, Int)) -> Int {
        if cell.0 > last.0 { return 4 } // entering through the west face
        if cell.0 < last.0 { return 5 }
        if cell.1 > last.1 { return 0 }
        if cell.1 < last.1 { return 1 }
        if cell.2 > last.2 { return 2 }
        return 3
    }
}
