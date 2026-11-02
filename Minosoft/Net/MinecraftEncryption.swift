import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The 1.20.4 online-mode handshake: RSA to the server's public key, the
/// signed SHA-1 server hash Mojang verifies, and the AES/CFB8 stream the rest
/// of the session rides on. Mirrors Minosoft's `CryptManager`.
enum MinecraftEncryption {
    /// SHA-1 over the server id, the shared secret and the server's public
    /// key, written as a signed big-endian hex number — the form the session
    /// server accepts.
    static func serverHash(serverId: String, publicKey: [UInt8], secret: [UInt8]) -> String {
        // Java hashes the id as ISO-8859-1; a modern server sends it empty.
        let idBytes = serverId.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        let digest = [UInt8](Insecure.SHA1.hash(data: Data(idBytes + secret + publicKey)))
        return signedHex(digest)
    }

    /// RSA/PKCS#1 encryption with the DER public key the server sent.
    static func encrypt(_ data: [UInt8], publicKeyDER: [UInt8]) throws -> [UInt8] {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(Data(publicKeyDER) as CFData, attributes as CFDictionary, nil) else {
            throw MCProtocolError.malformed("The server's encryption key could not be read.")
        }

        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(data) as CFData, &error) else {
            throw MCProtocolError.malformed("RSA encryption for the server failed.")
        }
        return [UInt8](encrypted as Data)
    }

    /// BigInteger's `toString(16)`: two's complement, no leading zeros, and a
    /// minus sign when the top bit is set.
    private static func signedHex(_ digest: [UInt8]) -> String {
        var bytes = digest
        let negative = bytes.first.map { $0 & 0x80 != 0 } ?? false

        if negative {
            var carry = true
            for index in stride(from: bytes.count - 1, through: 0, by: -1) {
                let inverted = ~digest[index]
                if carry {
                    let (value, overflow) = inverted.addingReportingOverflow(1)
                    bytes[index] = value
                    carry = overflow
                } else {
                    bytes[index] = inverted
                }
            }
        }

        var hex = bytes.map { String(format: "%02x", $0) }.joined()
        while hex.count > 1 && hex.hasPrefix("0") {
            hex.removeFirst()
        }
        return negative ? "-\(hex)" : hex
    }
}

/// One direction of the AES/CFB8 stream a session runs on. Minecraft restarts
/// the IV from the shared secret, so both directions share key and IV and
/// differ only in operation.
final class CFB8Cipher {
    private var cryptor: CCCryptorRef?

    init(key: [UInt8], iv: [UInt8], encrypting: Bool) throws {
        var reference: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                CCCryptorCreateWithMode(
                    CCOperation(encrypting ? kCCEncrypt : kCCDecrypt),
                    CCMode(kCCModeCFB8),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBuffer.baseAddress,
                    keyBuffer.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    0,
                    &reference
                )
            }
        }

        guard status == kCCSuccess, let reference else {
            throw MCProtocolError.malformed("The session's encrypted stream could not be set up.")
        }
        cryptor = reference
    }

    deinit {
        if let cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    /// CFB8 is a byte stream, so one call in is one call out, however long.
    func update(_ input: [UInt8]) throws -> [UInt8] {
        guard let cryptor else { throw MCProtocolError.connectionClosed }
        guard !input.isEmpty else { return [] }

        let length = input.count
        var output = [UInt8](repeating: 0, count: length)
        var moved = 0
        let status = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                CCCryptorUpdate(
                    cryptor,
                    inputBuffer.baseAddress,
                    length,
                    outputBuffer.baseAddress,
                    length,
                    &moved
                )
            }
        }

        guard status == kCCSuccess else {
            throw MCProtocolError.malformed("The session's encrypted stream broke.")
        }
        return Array(output.prefix(moved))
    }
}
