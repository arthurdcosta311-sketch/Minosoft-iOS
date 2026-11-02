import Foundation

/// Sable's slice: NBT, ported from Minosoft's NBT handling.
///
/// The protocol hands NBT around uncompressed in packets — chunk heightmaps,
/// block entity data, the configuration-state registry entries. No snbt, no
/// files, just the binary tree, which is all the client needs.
indirect enum NBTValue {
    case byte(Int8)
    case short(Int16)
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case byteArray([UInt8])
    case string(String)
    case list([NBTValue])
    case compound([String: NBTValue])
    case intArray([Int32])
    case longArray([Int64])

    var intValue: Int? {
        switch self {
        case .byte(let value): return Int(value)
        case .short(let value): return Int(value)
        case .int(let value): return Int(value)
        case .long(let value): return Int(value)
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var compoundValue: [String: NBTValue]? {
        if case .compound(let value) = self { return value }
        return nil
    }

    var listValue: [NBTValue]? {
        if case .list(let value) = self { return value }
        return nil
    }
}

enum NBT {
    /// Reads a named root tag and returns its compound payload.
    /// An empty payload (TAG_End) yields an empty dictionary, which is how the
    /// chunk heightmap arrives when the server has nothing to send.
    static func read(from buffer: MCBuffer) throws -> [String: NBTValue] {
        // 1.20.2+ packet NBT is unnamed: a type byte, then the payload. There
        // is no root name to skip, and roots can be bare strings (a chat
        // component is often just a TAG_String), so anything but END is
        // read as-is.
        let type = try buffer.readByte()
        guard type != 0 else { return [:] }
        let value = try readPayload(type: type, from: buffer)
        return value.compoundValue ?? [:]
    }

    /// Reads one unnamed payload: a tag type byte and its body, with no root
    /// name. 1.20.2+ uses this shape for packet-carried NBT (text components,
    /// registry entries, chunk heightmaps).
    static func readValue(from buffer: MCBuffer) throws -> NBTValue {
        let type = try buffer.readByte()
        guard type != 0 else { return .compound([:]) }
        return try readPayload(type: type, from: buffer)
    }

    private static func readPayload(type: UInt8, from buffer: MCBuffer) throws -> NBTValue {
        switch type {
        case 1:
            return .byte(Int8(bitPattern: try buffer.readByte()))
        case 2:
            return .short(try buffer.readShort())
        case 3:
            return .int(try buffer.readInt())
        case 4:
            return .long(try buffer.readLong())
        case 5:
            return .float(try buffer.readFloat())
        case 6:
            return .double(try buffer.readDouble())
        case 7:
            let length = try buffer.readInt()
            guard length >= 0, length <= 1 << 24 else { throw MCProtocolError.truncated }
            return .byteArray(try buffer.readBytes(Int(length)))
        case 8:
            return .string(try readNBTString(buffer))
        case 9:
            let elementType = try buffer.readByte()
            let length = try buffer.readInt()
            guard length >= 0, length <= 1 << 20 else { throw MCProtocolError.truncated }
            guard elementType != 0 else { return .list([]) }
            var values: [NBTValue] = []
            values.reserveCapacity(Int(length))
            for _ in 0..<Int(length) {
                values.append(try readPayload(type: elementType, from: buffer))
            }
            return .list(values)
        case 10:
            var entries: [String: NBTValue] = [:]
            while true {
                let childType = try buffer.readByte()
                if childType == 0 { break }
                let name = try readNBTString(buffer)
                entries[name] = try readPayload(type: childType, from: buffer)
            }
            return .compound(entries)
        case 11:
            let length = try buffer.readInt()
            guard length >= 0, length <= 1 << 20 else { throw MCProtocolError.truncated }
            var values: [Int32] = []
            values.reserveCapacity(Int(length))
            for _ in 0..<Int(length) { values.append(try buffer.readInt()) }
            return .intArray(values)
        case 12:
            let length = try buffer.readInt()
            guard length >= 0, length <= 1 << 20 else { throw MCProtocolError.truncated }
            var values: [Int64] = []
            values.reserveCapacity(Int(length))
            for _ in 0..<Int(length) { values.append(try buffer.readLong()) }
            return .longArray(values)
        default:
            throw MCProtocolError.truncated
        }
    }

    /// NBT strings are unsigned-short-prefixed UTF-8 — not the protocol's
    /// VarInt-prefixed strings that `MCBuffer.readString` reads.
    private static func readNBTString(_ buffer: MCBuffer) throws -> String {
        let length = Int(try buffer.readUShort())
        guard length >= 0, length <= 1 << 16 else { throw MCProtocolError.truncated }
        let bytes = try buffer.readBytes(length)
        return String(decoding: bytes, as: UTF8.self)
    }
}
