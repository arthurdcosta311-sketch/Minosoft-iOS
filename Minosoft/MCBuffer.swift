import Foundation

/// Errors every layer of the port shares, so UI can show one message regardless of origin.
enum MCProtocolError: Error, LocalizedError {
    case truncated
    case badVarInt
    case badPacket(id: Int)
    case badStatusResponse
    case connectionClosed
    case timeout
    /// The server sent something that does not fit the 1.20.4 format.
    case malformed(String)
    /// The server wants something the port cannot do yet (online mode, resource packs).
    case unsupported(String)
    /// The server rejected us: kicked, whitelist, version mismatch.
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .truncated: return "Packet data was truncated."
        case .badVarInt: return "Malformed VarInt."
        case .badPacket(let id): return "Unexpected packet id \(id)."
        case .badStatusResponse: return "The server's status response could not be parsed."
        case .connectionClosed: return "The connection closed."
        case .timeout: return "The connection timed out."
        case .malformed(let message): return message
        case .unsupported(let message): return message
        case .rejected(let message): return message
        }
    }
}

/// A block position, as the protocol packs it into a single long.
struct BlockPosition: Hashable {
    var x: Int
    var y: Int
    var z: Int
}

/// Kane's slice: the wire-format layer every packet goes through.
/// Read/write primitives matching the Minecraft protocol exactly (big-endian, VarInt framing).
/// Mirrors `de.bixilon.minosoft.protocol.protocol.buffers.InByteBuffer` upstream.
final class MCBuffer {
    private(set) var data: [UInt8]
    private var offset = 0

    init(data: [UInt8] = []) {
        self.data = data
    }

    /// Bytes read so far, one based like an upstream buffer offset.
    var position: Int { offset }

    var remaining: Int { data.count - offset }

    var isAtEnd: Bool { remaining <= 0 }

    // MARK: Reading

    func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw MCProtocolError.truncated }
        let byte = data[offset]
        offset += 1
        return byte
    }

    func readUnsignedByte() throws -> UInt8 {
        try readByte()
    }

    func readBoolean() throws -> Bool {
        try readByte() != 0
    }

    /// Spelling the session uses for booleans on the wire.
    func readBool() throws -> Bool {
        try readBoolean()
    }

    func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw MCProtocolError.truncated }
        let slice = Array(data[offset..<(offset + count)])
        offset += count
        return slice
    }

    /// Everything still unread; used where the payload's length is what defines the field.
    func readRemaining() throws -> [UInt8] {
        try readBytes(remaining)
    }

    /// A VarInt length followed by that many bytes (chunk data, plugin messages).
    func readByteArray() throws -> [UInt8] {
        let length = try readVarInt()
        guard length >= 0 else { throw MCProtocolError.malformed("Negative byte array length \(length).") }
        return try readBytes(length)
    }

    func skip(_ count: Int) throws {
        guard count >= 0, remaining >= count else { throw MCProtocolError.truncated }
        offset += count
    }

    func readVarInt() throws -> Int {
        var value: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            let byte = try readByte()
            if shift == 28 && byte & 0xF0 != 0 { throw MCProtocolError.badVarInt }
            value |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { throw MCProtocolError.badVarInt }
        }
        return Int(Int32(bitPattern: value))
    }

    func readString() throws -> String {
        let length = try readVarInt()
        // Status JSON with favicons is the longest string on the wire; anything past
        // this is a corrupt length, not a real string.
        guard length >= 0, length <= (1 << 21) else {
            throw MCProtocolError.malformed("String length \(length) is out of range.")
        }
        let bytes = try readBytes(length)
        return String(decoding: bytes, as: UTF8.self)
    }

    func readUShort() throws -> UInt16 {
        let bytes = try readBytes(2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    func readShort() throws -> Int16 {
        Int16(bitPattern: try readUShort())
    }

    func readInt() throws -> Int32 {
        let bytes = try readBytes(4)
        var value: UInt32 = 0
        for byte in bytes { value = value << 8 | UInt32(byte) }
        return Int32(bitPattern: value)
    }

    func readULong() throws -> UInt64 {
        let bytes = try readBytes(8)
        var value: UInt64 = 0
        for byte in bytes { value = value << 8 | UInt64(byte) }
        return value
    }

    func readLong() throws -> Int64 {
        Int64(bitPattern: try readULong())
    }

    func readFloat() throws -> Float {
        Float(bitPattern: UInt32(bitPattern: try readInt()))
    }

    func readDouble() throws -> Double {
        Double(bitPattern: try readULong())
    }

    func readUUID() throws -> UUID {
        let bytes = try readBytes(16)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Big-endian longs, as every packed data array on the wire (chunk sections, bitsets).
    func readLongArray(_ count: Int) throws -> [UInt64] {
        guard count >= 0, count * 8 <= remaining else { throw MCProtocolError.truncated }
        var values = [UInt64]()
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try readULong())
        }
        return values
    }

    /// A block position packed into one long since 1.14: x in the top 26 bits,
    /// z in the middle 26, y in the bottom 12 — each sign extended.
    func readPosition() throws -> BlockPosition {
        let raw = Int64(bitPattern: try readULong())
        return BlockPosition(
            x: Int(raw >> 38),
            y: Int((raw << 52) >> 52),
            z: Int((raw << 26) >> 38)
        )
    }

    // MARK: Writing

    func writeByte(_ byte: UInt8) {
        data.append(byte)
    }

    func writeBoolean(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    func writeBool(_ value: Bool) {
        writeBoolean(value)
    }

    func writeVarInt(_ value: Int) {
        var remaining = UInt32(truncatingIfNeeded: value)
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }

    func writeString(_ string: String) {
        let bytes = Array(string.utf8)
        writeVarInt(bytes.count)
        data.append(contentsOf: bytes)
    }

    func writeUShort(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    func writeShort(_ value: Int16) {
        writeUShort(UInt16(bitPattern: value))
    }

    func writeInt(_ value: Int32) {
        let bits = UInt32(bitPattern: value)
        data.append(UInt8((bits >> 24) & 0xFF))
        data.append(UInt8((bits >> 16) & 0xFF))
        data.append(UInt8((bits >> 8) & 0xFF))
        data.append(UInt8(bits & 0xFF))
    }

    func writeULong(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    func writeLong(_ value: Int64) {
        writeULong(UInt64(bitPattern: value))
    }

    func writeFloat(_ value: Float) {
        writeInt(Int32(bitPattern: value.bitPattern))
    }

    func writeDouble(_ value: Double) {
        writeULong(value.bitPattern)
    }

    func writeUUID(_ uuid: UUID) {
        var raw = uuid.uuid
        withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
    }

    func writeBytes(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    /// A VarInt length followed by that many bytes — what the encryption
    /// handshake's keys and verify token travel in.
    func writeByteArray(_ bytes: [UInt8]) {
        writeVarInt(bytes.count)
        writeBytes(bytes)
    }

    func writePosition(_ position: BlockPosition) {
        let x = UInt64(truncatingIfNeeded: position.x) & 0x3FFFFFF
        let y = UInt64(truncatingIfNeeded: position.y) & 0xFFF
        let z = UInt64(truncatingIfNeeded: position.z) & 0x3FFFFFF
        writeULong((x << 38) | (z << 12) | y)
    }

    // MARK: Framing

    /// Wraps this buffer's payload in a length-prefixed packet (no compression in status state).
    func framed() -> [UInt8] {
        let out = MCBuffer()
        out.writeVarInt(data.count)
        out.writeBytes(data)
        return out.data
    }
}
