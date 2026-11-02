import CryptoKit
import Foundation
import Security

/// Kane + Sable's slice: the 1.20.4 session machine.
///
/// handshake → login (with Set Compression) → login success → configuration
/// handshake → play loop (keepalives, teleports, chat, chunk batches).
/// Every id comes from Net/Protocol.swift, which is Minosoft's own
/// versions.json mapping. Packets we cannot parse yet are skipped, never
/// fatal: a missing id degrades a feature, a bad parse never takes the
/// session down.
final class MCSession {
    enum SessionEvent {
        case state(ConnectionState)
        case chat(String)
        case position(SIMD3<Double>, yaw: Float, pitch: Float)
        case kicked(String)
    }

    let events: AsyncStream<SessionEvent>
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation

    /// Chunks land here as they arrive; the renderer reads it straight off.
    let world = VoxelWorld()

    private var connection: TCPConnection?
    /// Who we claim to be; an online-mode login carries the profile UUID.
    private var account: Account?
    /// Both directions of the AES/CFB8 stream, once the server asked for it.
    private var encryption: (encrypt: CFB8Cipher, decrypt: CFB8Cipher)?
    /// nil until the server sends Set Compression; 0 means "always compress".
    private var compressionThreshold: Int?
    private let sendLock = SessionSendLock()
    private var closed = false
    private var dimensionTypes: [String: (minY: Int, height: Int)] = [:]
    private var playerPosition = SIMD3<Double>(0, 0, 0)
    private var playerYaw: Float = 0
    private var playerPitch: Float = 0

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        events = stream
        eventContinuation = continuation
    }

    func connect(host: String, port: UInt16, account: Account) async throws {
        self.account = account
        guard let connection = TCPConnection(host: host, port: port) else {
            throw MCProtocolError.badPacket(id: Int(port))
        }
        self.connection = connection
        try await connection.connect()

        emit(.state(.loggingIn))
        try await sendHandshake(host: host, port: port)
        try await login(username: account.username, uuid: account.uuid)
        try await configure()

        emit(.state(.playing))
        Task { try? await playLoop() }
    }

    // MARK: Phases

    private func sendHandshake(host: String, port: UInt16) async throws {
        let body = MCBuffer()
        body.writeVarInt(Protocol.number)
        body.writeString(host)
        body.writeUShort(port)
        body.writeVarInt(HandshakePacket.nextStateLogin)
        try await sendPacket(HandshakePacket.id, body)
    }

    private func login(username: String, uuid: UUID?) async throws {
        let start = MCBuffer()
        start.writeString(username)
        // 1.20.4's login start carries the profile UUID: the signed-in one in
        // online mode, the name-derived one offline.
        start.writeUUID(uuid ?? Self.offlineUUID(username))
        try await sendPacket(LoginPacket.C2S.start, start)

        while true {
            let packet = try await readPacket()
            let id = try packet.readVarInt()
            switch id {
            case LoginPacket.S2C.compression:
                compressionThreshold = try packet.readVarInt()
            case LoginPacket.S2C.success:
                _ = try packet.readUUID() // UUID
                _ = try packet.readString() // username echo
                // Signed profile properties trail the username; we carry none,
                // but the reader still has to walk them.
                let propertyCount = try packet.readVarInt()
                guard propertyCount >= 0, propertyCount <= 1024 else {
                    throw MCProtocolError.malformed("Login success claimed \(propertyCount) profile properties.")
                }
                for _ in 0..<propertyCount {
                    _ = try packet.readString() // name
                    _ = try packet.readString() // value
                    if try packet.readBoolean() {
                        _ = try packet.readString() // signature
                    }
                }
                // 1.20.2+ servers wait in login until this lands; without it
                // the configuration phase never starts.
                try await sendPacket(LoginPacket.C2S.loginAcknowledged, MCBuffer())
                return

            case LoginPacket.S2C.loginPluginRequest:
                // Answer "we can't do that", or some servers wait forever.
                let messageId = try packet.readVarInt()
                let reply = MCBuffer()
                reply.writeVarInt(messageId)
                reply.writeBoolean(false)
                try await sendPacket(LoginPacket.C2S.loginPluginResponse, reply)
            case LoginPacket.S2C.disconnect:
                // 1.20.2+ sends kick reasons as unnamed NBT text components.
                let component = try? NBT.readValue(from: packet)
                let reason = component.map { ChatText.extract($0) } ?? "Disconnected"
                throw MCProtocolError.rejected(reason)
            case LoginPacket.S2C.encryptionRequest:
                try await enableEncryption(request: packet)
            default:
                continue // login plugin requests et al. are answered with nothing; servers proceed
            }
        }
    }

    /// The online-mode handshake, mirroring Minosoft's `EncryptionS2CP` and
    /// `CryptManager`: a fresh shared secret, the session-server join, then the
    /// RSA-sealed secret and verify token, and from there every byte on the
    /// connection runs through AES/CFB8.
    private func enableEncryption(request: MCBuffer) async throws {
        guard let account, let signedIn = account.signedIn else {
            throw MCProtocolError.unsupported(
                "This server is in online mode and verifies your Minecraft profile. Sign in with a Microsoft account in Player settings (the person icon), then join again."
            )
        }

        let serverId = try request.readString()
        let publicKey = try request.readByteArray()
        let verifyToken = try request.readByteArray()

        var secret = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else {
            throw MCProtocolError.malformed("Could not generate the session's shared secret.")
        }

        // The tokens may have run out while the server list sat open, so the
        // join is made with a fresh Minecraft token.
        let fresh = try await MicrosoftAuth.refreshing(account)
        guard let tokens = fresh.session else {
            throw MCProtocolError.unsupported("The Microsoft sign-in for this account is not valid any more. Sign in again.")
        }
        self.account = fresh

        let hash = MinecraftEncryption.serverHash(serverId: serverId, publicKey: publicKey, secret: secret)
        try await MicrosoftAuth.joinServer(hash: hash, uuid: signedIn.uuid, accessToken: tokens.minecraftAccessToken)

        let response = MCBuffer()
        response.writeByteArray(try MinecraftEncryption.encrypt(secret, publicKeyDER: publicKey))
        response.writeByteArray(try MinecraftEncryption.encrypt(verifyToken, publicKeyDER: publicKey))
        // Unencrypted: the server only switches once it has read this.
        try await sendPacket(LoginPacket.C2S.encryption, response)

        encryption = (
            encrypt: try CFB8Cipher(key: secret, iv: secret, encrypting: true),
            decrypt: try CFB8Cipher(key: secret, iv: secret, encrypting: false)
        )

        await AccountStore.shared.update(fresh)
    }

    private func configure() async throws {
        let settings = MCBuffer()
        settings.writeString("en_us")
        settings.writeByte(8)
        settings.writeVarInt(0)
        settings.writeBool(true)
        settings.writeByte(0x7F)
        settings.writeVarInt(1)
        settings.writeBool(false)
        settings.writeBool(true)
        try await sendPacket(ConfigurationPacket.C2S.settings, settings)

        while true {
            let packet = try await readPacket()
            let id = try packet.readVarInt()
            switch id {
            case ConfigurationPacket.S2C.finishConfiguration:
                try await sendPacket(ConfigurationPacket.C2S.ready, MCBuffer())
                return
            case ConfigurationPacket.S2C.keepAlive:
                let token = try packet.readULong()
                let reply = MCBuffer(); reply.writeULong(token)
                try await sendPacket(ConfigurationPacket.C2S.keepAlive, reply)
            case ConfigurationPacket.S2C.ping:
                // Pings are longs in every state since 1.12.2.
                let number = try packet.readULong()
                let reply = MCBuffer(); reply.writeULong(number)
                try await sendPacket(ConfigurationPacket.C2S.pong, reply)
            case ConfigurationPacket.S2C.registries:
                let registries = try NBT.read(from: packet)
                readDimensionTypes(from: registries)
            case ConfigurationPacket.S2C.disconnect:
                // Unnamed NBT text component, same as the login-state kick.
                let component = try? NBT.readValue(from: packet)
                let reason = component.map { ChatText.extract($0) } ?? "Disconnected"
                throw MCProtocolError.rejected(reason)
            default:
                continue // features, resource packs and tags do not affect the play decoder
            }
        }
    }

    /// Retains the server's dimension type registry so custom dimensions use the
    /// same section range as their `dimension_type` NBT definition.
    private func readDimensionTypes(from registries: [String: NBTValue]) {
        guard let entries = registries["minecraft:dimension_type"]?.compoundValue?["value"]?.listValue else {
            return
        }

        for entry in entries {
            guard let fields = entry.compoundValue,
                  let name = fields["name"]?.stringValue,
                  let element = fields["element"]?.compoundValue,
                  let minY = element["min_y"]?.intValue,
                  let height = element["height"]?.intValue,
                  height > 0, height <= 4096,
                  minY.isMultiple(of: 16), height.isMultiple(of: 16) else {
                continue
            }
            dimensionTypes[name] = (minY, height)
        }
    }

    /// Reads 1.20.4's Join Game packet and configures the world from the server's
    /// dimension type, falling back to the three vanilla dimensions if registry
    /// data omitted the definition.
    private func readJoinGame(from packet: MCBuffer) throws {
        _ = try packet.readInt() // entity id
        _ = try packet.readBoolean() // hardcore
        let dimensionCount = try packet.readVarInt()
        guard dimensionCount >= 0, dimensionCount <= 256 else {
            throw MCProtocolError.malformed("Join Game declared \(dimensionCount) dimensions.")
        }
        for _ in 0..<dimensionCount {
            _ = try packet.readString()
        }
        _ = try packet.readVarInt() // max players
        _ = try packet.readVarInt() // view distance
        _ = try packet.readVarInt() // simulation distance
        _ = try packet.readBoolean() // reduced debug info
        _ = try packet.readBoolean() // enable respawn screen
        _ = try packet.readBoolean() // limited crafting

        let dimensionType = try packet.readString()
        _ = try packet.readString() // dimension name
        _ = try packet.readLong() // hashed seed
        _ = try packet.readByte() // game mode
        _ = try packet.readByte() // previous game mode
        _ = try packet.readBoolean() // debug world
        _ = try packet.readBoolean() // flat world
        if try packet.readBoolean() { // has death location
            _ = try packet.readString()
            _ = try packet.readPosition()
        }
        _ = try packet.readVarInt() // portal cooldown

        let definition = dimensionTypes[dimensionType] ?? Self.vanillaDimension(dimensionType)
        world.configure(minY: definition.minY, height: definition.height)
    }

    private static func vanillaDimension(_ identifier: String) -> (minY: Int, height: Int) {
        if identifier == "minecraft:overworld" {
            return (-64, 384)
        }
        return (0, 256)
    }

    private func playLoop() async throws {
        while true {
            let packet: MCBuffer
            do {
                packet = try await readPacket()
            } catch {
                emit(.kicked("Connection lost"))
                close()
                return
            }
            guard let id = try? packet.readVarInt() else { continue }

            do {
                switch id {
                case PlayPacket.S2C.joinGame:
                    try readJoinGame(from: packet)

                case PlayPacket.S2C.keepAlive:
                    let token = try packet.readULong()
                    let reply = MCBuffer(); reply.writeULong(token)
                    try await sendPacket(PlayPacket.C2S.keepAlive, reply)

                case PlayPacket.S2C.playerPosition:
                    // Synchronize Player Position (0x3E): absolute or relative fields,
                    // followed by the teleport id. Entity Teleport (0x6D) is unrelated.
                    let x = try packet.readDouble()
                    let y = try packet.readDouble()
                    let z = try packet.readDouble()
                    let yaw = try packet.readFloat()
                    let pitch = try packet.readFloat()
                    let flags = try packet.readByte()
                    let teleportID = try packet.readVarInt()

                    playerPosition = SIMD3<Double>(
                        flags & 0x01 != 0 ? playerPosition.x + x : x,
                        flags & 0x02 != 0 ? playerPosition.y + y : y,
                        flags & 0x04 != 0 ? playerPosition.z + z : z
                    )
                    playerYaw = flags & 0x08 != 0 ? playerYaw + yaw : yaw
                    playerPitch = flags & 0x10 != 0 ? playerPitch + pitch : pitch

                    let confirm = MCBuffer(); confirm.writeVarInt(teleportID)
                    try await sendPacket(PlayPacket.C2S.confirmTeleport, confirm)
                    emit(.position(playerPosition, yaw: playerYaw, pitch: playerPitch))

                case PlayPacket.S2C.systemChat:
                    // 1.20.3+ sends chat components as NBT, not JSON.
                    let component = try NBT.readValue(from: packet)
                    _ = try packet.readBool() // overlay flag
                    let text = ChatText.extract(component)
                    if !text.isEmpty { emit(.chat(text)) }

                case PlayPacket.S2C.disconnect:
                    let component = try? NBT.readValue(from: packet)
                    let reason = component.map { ChatText.extract($0) } ?? "Disconnected"
                    emit(.kicked(reason))
                    close()
                    return

                case PlayPacket.S2C.ping:
                    // The play-state ping is a long, same as configuration's.
                    let number = try packet.readULong()
                    let reply = MCBuffer(); reply.writeULong(number)
                    try await sendPacket(PlayPacket.C2S.pong, reply)

                case PlayPacket.S2C.chunkBatchFinished:
                    // Acknowledge the batch generously so the server keeps streaming chunks.
                    let reply = MCBuffer(); reply.writeFloat(1024.0)
                    try await sendPacket(PlayPacket.C2S.chunkBatchReceived, reply)

                case PlayPacket.S2C.chunkData:
                    // Sable's decoder: paletted sections out of the chunk packet.
                    if let chunk = try? ChunkDecoder.readChunk(
                        from: packet,
                        minY: world.minY,
                        sectionCount: world.sectionCount
                    ) {
                        world.insert(chunkX: chunk.x, chunkZ: chunk.z, sections: chunk.sections)
                    }

                case PlayPacket.S2C.unloadChunk:
                    // 1.20.4 sends the packed long with Z in its upper 32 bits, then X.
                    let chunkZ = Int(try packet.readInt())
                    let chunkX = Int(try packet.readInt())
                    world.removeChunk(x: chunkX, z: chunkZ)

                case PlayPacket.S2C.blockUpdate:
                    let position = try packet.readPosition()
                    let state = try packet.readVarInt()
                    world.setBlock(
                        state: UInt16(truncatingIfNeeded: state),
                        x: position.x, y: position.y, z: position.z
                    )

                default:
                    break // entities, HUD data, sounds: later slices
                }
            } catch {
                continue // one bad packet never ends the session
            }
        }
    }

    // MARK: Outgoing, for the bridge

    func sendChat(_ text: String) {
        guard !closed, !text.isEmpty, text.utf16.count <= 256 else { return }
        let body = MCBuffer()
        body.writeString(text)
        // 1.20.4 unsigned chat: message, timestamp, salt, no signature, then
        // last-seen message count and the fixed 20-byte acknowledgement bitset.
        body.writeLong(Int64(Date().timeIntervalSince1970 * 1000))
        body.writeLong(0)
        body.writeBoolean(false) // no 256-byte signature follows
        body.writeVarInt(0)      // no last-seen messages
        body.writeBytes([UInt8](repeating: 0, count: 20))
        Task { try? await sendPacket(PlayPacket.C2S.chatMessage, body) }
    }

    func swingArm() {
        guard !closed else { return }
        let body = MCBuffer()
        body.writeVarInt(0) // main hand
        Task { try? await sendPacket(PlayPacket.C2S.swingArm, body) }
    }

    func sendMovement(position: SIMD3<Double>, yaw: Float, pitch: Float, onGround: Bool) {
        guard !closed else { return }
        let body = MCBuffer()
        body.writeDouble(position.x)
        body.writeDouble(position.y)
        body.writeDouble(position.z)
        body.writeFloat(yaw)
        body.writeFloat(pitch)
        body.writeBool(onGround)
        Task { try? await sendPacket(PlayPacket.C2S.setPlayerPositionAndRotation, body) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        encryption = nil
        connection?.close()
        connection = nil
        eventContinuation.finish()
    }

    // MARK: Framing

    private func readPacket() async throws -> MCBuffer {
        let total = try await readFrameLength()

        if compressionThreshold == nil {
            return MCBuffer(data: try await readWireBytes(total))
        }

        let framed = MCBuffer(data: try await readWireBytes(total))
        let uncompressedLength = try framed.readVarInt()
        let rest = try framed.readRemaining()
        guard uncompressedLength == 0 else {
            return MCBuffer(data: try MCZlib.inflate(rest, expectedSize: uncompressedLength))
        }
        return MCBuffer(data: rest)
    }

    /// One byte off the wire, decrypted first once the session is encrypted.
    /// CFB8 is a byte stream, so single-byte reads keep its state intact.
    private func readWireByte() async throws -> UInt8 {
        guard let connection else { throw MCProtocolError.connectionClosed }
        let raw = try await connection.readByte()
        guard let encryption else { return raw }
        guard let byte = try encryption.decrypt.update([raw]).first else {
            throw MCProtocolError.truncated
        }
        return byte
    }

    private func readWireBytes(_ count: Int) async throws -> [UInt8] {
        guard let connection else { throw MCProtocolError.connectionClosed }
        let raw = try await connection.readBytes(count)
        guard let encryption else { return raw }
        return try encryption.decrypt.update(raw)
    }

    private func readFrameLength() async throws -> Int {
        var length: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            let byte = try await readWireByte()
            if shift == 28 && byte & 0xF0 != 0 { throw MCProtocolError.badVarInt }
            length |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { throw MCProtocolError.badVarInt }
        }
        let packetLength = Int(Int32(bitPattern: length))
        guard packetLength > 0, packetLength <= Protocol.maxPacketLength else {
            throw MCProtocolError.badPacket(id: packetLength)
        }
        return packetLength
    }

    private func sendPacket(_ id: Int, _ body: MCBuffer) async throws {
        guard let connection, !closed else { throw MCProtocolError.connectionClosed }
        let payload = MCBuffer()
        payload.writeVarInt(id)
        payload.writeBytes(body.data)

        let frame = MCBuffer()
        if let threshold = compressionThreshold {
            if payload.data.count >= threshold {
                let compressed = try MCZlib.deflate(payload.data)
                frame.writeVarInt(compressed.count + varIntLength(payload.data.count))
                frame.writeVarInt(payload.data.count)
                frame.writeBytes(compressed)
            } else {
                frame.writeVarInt(payload.data.count + 1)
                frame.writeVarInt(0)
                frame.writeBytes(payload.data)
            }
        } else {
            frame.writeVarInt(payload.data.count)
            frame.writeBytes(payload.data)
        }

        // Compression sits inside encryption: frame first, then seal.
        let outbound = try encryption?.encrypt.update(frame.data) ?? frame.data

        await sendLock.acquire()
        do {
            try await connection.send(outbound)
            await sendLock.release()
        } catch {
            await sendLock.release()
            throw error
        }
    }

    private func varIntLength(_ value: Int) -> Int {
        var remaining = UInt32(truncatingIfNeeded: value)
        var count = 0
        repeat {
            remaining >>= 7
            count += 1
        } while remaining != 0
        return count
    }

    private func emit(_ event: SessionEvent) {
        eventContinuation.yield(event)
    }

    /// The UUID an offline-mode server would derive for this name
    /// (`UUID.nameUUIDFromBytes("OfflinePlayer:<name>")` — MD5, version 3).
    private static func offlineUUID(_ username: String) -> UUID {
        var digest = [UInt8](Insecure.MD5.hash(data: Data("OfflinePlayer:\(username)".utf8)))
        digest[6] = (digest[6] & 0x0F) | 0x30
        digest[8] = (digest[8] & 0x3F) | 0x80

        let hex = digest[0..<16].map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: formatted) ?? UUID()
    }
}


/// Serializes packet writes without holding a thread lock across an async suspension.
private actor SessionSendLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
