import Compression
import Foundation

/// Kane's slice: zlib, as Minecraft packets speak it.
///
/// Apple's `COMPRESSION_ZLIB` is bare DEFLATE — it neither writes nor expects the
/// two byte zlib header and four byte Adler-32 trailer that Java's `Deflater`
/// produces, so this adds that framing on the way out and strips it on the way in.
/// The deflate side doubles its buffer until the whole payload fits, because Apple's
/// encoder reports only "0 bytes written" when the output would not fit.
enum MCZlib {
    static func deflate(_ input: [UInt8]) throws -> [UInt8] {
        guard !input.isEmpty else { return [0x78, 0x9C] }

        var capacity = max(input.count + 64, 256)
        while capacity <= (8 << 20) {
            var output = [UInt8](repeating: 0, count: capacity)
            let written: Int = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    guard let sourceBase = source.baseAddress,
                          let destinationBase = destination.baseAddress
                    else { return 0 }
                    return compression_encode_buffer(
                        destinationBase, capacity,
                        sourceBase, input.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }

            if written > 0 && written < capacity {
                return [0x78, 0x9C] + output[0..<written] + adler32(input)
            }
            capacity *= 2
        }
        throw MCProtocolError.malformed("Could not compress a packet.")
    }

    static func inflate(_ input: [UInt8], size: Int) throws -> [UInt8] {
        guard size > 0 else { return [] }
        guard input.count > 6 else {
            throw MCProtocolError.malformed("Truncated compressed packet.")
        }

        let stripped = Array(input[2..<(input.count - 4)])
        var output = [UInt8](repeating: 0, count: size)
        let written: Int = stripped.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase, size,
                    sourceBase, stripped.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written == size else {
            throw MCProtocolError.malformed("Could not decompress a packet (\(size) bytes expected).")
        }
        return output
    }

    /// Spelling used by the session: the expected decompressed byte count.
    static func inflate(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        try inflate(input, size: expectedSize)
    }

    private static func adler32(_ data: [UInt8]) -> [UInt8] {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in data {
            low = (low + UInt32(byte)) % 65521
            high = (high + low) % 65521
        }
        let checksum = (high << 16) | low
        return [
            UInt8((checksum >> 24) & 0xFF),
            UInt8((checksum >> 16) & 0xFF),
            UInt8((checksum >> 8) & 0xFF),
            UInt8(checksum & 0xFF),
        ]
    }
}
