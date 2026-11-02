import Foundation

/// Sable's slice: the 1.20.4 chunk packet, decoded into flat block-state arrays.
/// Mirrors upstream `ChunkS2CP` → `ChunkPacketUtil.readPaletteChunk` →
/// `PalettedContainerReader.unpack` for flattened block and biome palettes.
enum ChunkDecoder {
    struct DecodedSection {
        var blocks: [UInt16]
        /// Temporary section-wide brightness estimate. Per-block sky and block
        /// light arrays are transported separately by the protocol's light masks.
        var skyLight: Float
    }

    struct DecodedChunk {
        let x: Int
        let z: Int
        let sections: [DecodedSection]
    }

    private static let blocksPerSection = 4096
    private static let biomesPerSection = 64
    private static let maximumNBTDepth = 256
    private static let maximumArrayLength = 1 << 20

    /// The 1.20.4 Chunk Data packet: X/Z, heightmaps, size-prefixed section data,
    /// then block entities and light data. `sectionCount` comes from the Join Game
    /// dimension type; unlike pre-1.18 packets, sections are not bitmasked/skipped.
    static func readChunk(
        from buffer: MCBuffer,
        minY: Int,
        sectionCount: Int
    ) throws -> DecodedChunk {
        guard minY.isMultiple(of: 16), sectionCount > 0, sectionCount <= 256 else {
            throw MCProtocolError.malformed("Invalid chunk dimension bounds.")
        }

        let chunkX = Int(try buffer.readInt())
        let chunkZ = Int(try buffer.readInt())
        let heightmaps = try NBT.read(from: buffer)
        let surface = surfaceHeights(heightmaps, minY: minY, height: sectionCount * 16)
        let payload = try buffer.readByteArray()
        let data = MCBuffer(data: payload)

        var sections: [DecodedSection] = []
        sections.reserveCapacity(sectionCount)

        // 1.18+ sends every section, bottom-to-top, including empty sections.
        // Use the registry-defined dimension height rather than guessing from the
        // remaining byte count: packet data may contain harmless trailing padding.
        for sectionIndex in 0..<sectionCount {
            guard data.remaining >= 2 else {
                throw MCProtocolError.malformed("Chunk ended before section \(sectionIndex).")
            }
            _ = try data.readShort() // non-air block count

            let blocks = try readPalette(
                from: data,
                count: blocksPerSection,
                minimumIndirectBits: 4,
                maximumIndirectBits: 8
            )
            _ = try readPalette(
                from: data,
                count: biomesPerSection,
                minimumIndirectBits: 1,
                maximumIndirectBits: 3
            )

            let sectionBottom = minY + sectionIndex * 16
            sections.append(DecodedSection(
                blocks: blocks.map { UInt16(truncatingIfNeeded: $0) },
                skyLight: skyLight(forSectionAt: sectionBottom, surface: surface)
            ))
        }

        // Any extra bytes in the declared data array are deliberately ignored. The
        // outer packet cursor already advanced by its exact VarInt byte length.
        let chunk = DecodedChunk(x: chunkX, z: chunkZ, sections: sections)
        try skipBlockEntitiesAndLight(from: buffer)
        return chunk
    }

    // MARK: Paletted containers

    private static func readPalette(
        from buffer: MCBuffer,
        count: Int,
        minimumIndirectBits: Int,
        maximumIndirectBits: Int
    ) throws -> [Int] {
        let wireBits = Int(try buffer.readUnsignedByte())
        guard wireBits <= 32 else {
            throw MCProtocolError.malformed("A palette claimed \(wireBits) bits per entry.")
        }

        var palette: [Int] = []
        let bits: Int
        if wireBits == 0 {
            bits = 0
            palette = [try buffer.readVarInt()]
        } else if wireBits <= maximumIndirectBits {
            // Upstream BlockStatePaletteFactory raises block palettes below 4 BPE
            // to 4; biome palettes keep their 1–3 BPE unchanged.
            bits = max(wireBits, minimumIndirectBits)
            let size = try buffer.readVarInt()
            guard size >= 0, size <= (1 << bits), size <= count else {
                throw MCProtocolError.malformed("A palette claimed \(size) entries.")
            }
            palette.reserveCapacity(size)
            for _ in 0..<size {
                palette.append(try buffer.readVarInt())
            }
        } else {
            bits = wireBits // direct registry IDs; no palette list
        }

        let longCount = try buffer.readVarInt()
        guard longCount >= 0, longCount <= maximumArrayLength else {
            throw MCProtocolError.malformed("A palette claimed \(longCount) longs of data.")
        }
        let longs = try buffer.readLongArray(longCount)

        if bits == 0 {
            return [Int](repeating: palette.first ?? 0, count: count)
        }

        let valuesPerLong = 64 / bits
        guard valuesPerLong > 0 else {
            throw MCProtocolError.malformed("Invalid palette entry width \(bits).")
        }
        let mask = (UInt64(1) << UInt64(bits)) - 1
        var values = [Int](repeating: 0, count: count)

        for index in 0..<count {
            let longIndex = index / valuesPerLong
            guard longIndex < longs.count else { break }
            let shift = UInt64((index % valuesPerLong) * bits)
            let raw = Int((longs[longIndex] >> shift) & mask)
            if palette.isEmpty {
                values[index] = raw
            } else if raw < palette.count {
                values[index] = palette[raw]
            }
        }
        return values
    }

    // MARK: Heightmaps / temporary brightness estimate

    private static func surfaceHeights(
        _ heightmaps: [String: NBTValue],
        minY: Int,
        height: Int
    ) -> [Int] {
        guard case .longArray(let packed)? = heightmaps["MOTION_BLOCKING"] ?? heightmaps["WORLD_SURFACE"] else {
            return []
        }

        let bits = max(1, Int(ceil(log2(Double(height + 1)))))
        let valuesPerLong = 64 / bits
        let mask = (UInt64(1) << UInt64(bits)) - 1
        var heights: [Int] = []
        heights.reserveCapacity(256)

        for index in 0..<256 {
            let longIndex = index / valuesPerLong
            guard longIndex < packed.count else { break }
            let value = (UInt64(bitPattern: packed[longIndex]) >> UInt64((index % valuesPerLong) * bits)) & mask
            heights.append(minY + Int(value))
        }
        return heights
    }

    private static func skyLight(forSectionAt bottom: Int, surface: [Int]) -> Float {
        guard let highest = surface.max() else {
            return bottom >= 0 ? 1.0 : 0.55
        }
        if bottom >= highest { return 1.0 }
        if bottom + 16 > highest { return 0.8 }
        return 0.5
    }

    // MARK: Block entities / light tail

    /// After the chunk data and block entity array, 1.20.4 carries four light
    /// masks followed by sky/block light arrays. Keep the packet cursor aligned;
    /// scalar light sampling will replace the current heightmap estimate later.
    private static func skipBlockEntitiesAndLight(from buffer: MCBuffer) throws {
        let blockEntityCount = try buffer.readVarInt()
        guard blockEntityCount >= 0, blockEntityCount <= 4096 else {
            throw MCProtocolError.malformed("Chunk declared \(blockEntityCount) block entities.")
        }
        for _ in 0..<blockEntityCount {
            _ = try buffer.readUnsignedByte() // packed XZ
            _ = try buffer.readShort() // Y
            _ = try buffer.readVarInt() // block entity type
            try skipNBT(from: buffer, depth: 0)
        }

        // In protocol 765, Chunk Data and Update Light carries the trust-edges
        // flag before its four light masks (upstream reads it in ChunkLightS2CP).
        _ = try buffer.readBoolean()
        for _ in 0..<4 {
            try skipBitSet(from: buffer)
        }
        try skipLightArrays(from: buffer)
        try skipLightArrays(from: buffer)
    }

    private static func skipBitSet(from buffer: MCBuffer) throws {
        let count = try buffer.readVarInt()
        guard count >= 0, count <= 64 else {
            throw MCProtocolError.malformed("Light mask has \(count) longs.")
        }
        _ = try buffer.readLongArray(count)
    }

    private static func skipLightArrays(from buffer: MCBuffer) throws {
        let count = try buffer.readVarInt()
        guard count >= 0, count <= 258 else {
            throw MCProtocolError.malformed("Light packet has \(count) arrays.")
        }
        for _ in 0..<count {
            let length = try buffer.readVarInt()
            guard length >= 0, length <= 2048 else {
                throw MCProtocolError.malformed("Light array has invalid length \(length).")
            }
            _ = try buffer.readBytes(length)
        }
    }

    private static func skipNBT(from buffer: MCBuffer, depth: Int) throws {
        guard depth <= maximumNBTDepth else {
            throw MCProtocolError.malformed("Block entity NBT nesting is too deep.")
        }
        let type = try buffer.readUnsignedByte()
        guard type != 0 else { return }
        try skipPayload(type: type, from: buffer, depth: depth)
    }

    private static func skipPayload(type: UInt8, from buffer: MCBuffer, depth: Int) throws {
        guard depth <= maximumNBTDepth else {
            throw MCProtocolError.malformed("Block entity NBT nesting is too deep.")
        }
        switch type {
        case 1: _ = try buffer.readByte()
        case 2: _ = try buffer.readShort()
        case 3, 5: _ = try buffer.readInt()
        case 4, 6: _ = try buffer.readLong()
        case 7:
            let length = Int(try buffer.readInt())
            guard length >= 0, length <= maximumArrayLength else { throw MCProtocolError.truncated }
            _ = try buffer.readBytes(length)
        case 8:
            let length = Int(try buffer.readUShort())
            _ = try buffer.readBytes(length)
        case 9:
            let elementType = try buffer.readUnsignedByte()
            let length = Int(try buffer.readInt())
            guard length >= 0, length <= maximumArrayLength else { throw MCProtocolError.truncated }
            if elementType != 0 {
                for _ in 0..<length {
                    try skipPayload(type: elementType, from: buffer, depth: depth + 1)
                }
            }
        case 10:
            while true {
                let childType = try buffer.readUnsignedByte()
                if childType == 0 { break }
                let nameLength = Int(try buffer.readUShort())
                _ = try buffer.readBytes(nameLength)
                try skipPayload(type: childType, from: buffer, depth: depth + 1)
            }
        case 11:
            let length = Int(try buffer.readInt())
            guard length >= 0, length <= maximumArrayLength else { throw MCProtocolError.truncated }
            _ = try buffer.readBytes(length * 4)
        case 12:
            let length = Int(try buffer.readInt())
            guard length >= 0, length <= maximumArrayLength else { throw MCProtocolError.truncated }
            _ = try buffer.readBytes(length * 8)
        default:
            throw MCProtocolError.malformed("Unknown NBT tag \(type).")
        }
    }
}
