import Foundation

struct ServerStatus {
    let motd: String
    let playersOnline: Int
    let playersMax: Int
    let versionName: String
    let latencyMs: Int?
}

enum MinecraftPing {
    static let protocolVersion = 765

    static func ping(host: String, port: UInt16) async throws -> ServerStatus {
        guard let connection = TCPConnection(host: host, port: port) else {
            throw MCProtocolError.badPacket(id: Int(port))
        }
        defer { connection.close() }

        try await connection.connect()

        let handshake = MCBuffer()
        handshake.writeVarInt(0x00)
        handshake.writeVarInt(protocolVersion)
        handshake.writeString(host)
        handshake.writeUShort(port)
        handshake.writeVarInt(1)
        try await connection.send(handshake.framed())

        let request = MCBuffer()
        request.writeVarInt(0x00)
        try await connection.send(request.framed())

        let payload = try await readPacket(connection)
        let response = MCBuffer(data: payload)
        let responseId = try response.readVarInt()
        guard responseId == 0x00 else { throw MCProtocolError.badPacket(id: responseId) }
        let json = try response.readString()
        let status = try parseStatus(json)

        let nonce = UInt64.random(in: .min ... .max)
        let pingPacket = MCBuffer()
        pingPacket.writeVarInt(0x01)
        pingPacket.writeULong(nonce)
        let sentAt = Date()
        try await connection.send(pingPacket.framed())

        let pongPayload = try await readPacket(connection)
        let pong = MCBuffer(data: pongPayload)
        let pongId = try pong.readVarInt()
        guard pongId == 0x01, try pong.readULong() == nonce else {
            throw MCProtocolError.badPacket(id: pongId)
        }

        return ServerStatus(
            motd: status.motd,
            playersOnline: status.playersOnline,
            playersMax: status.playersMax,
            versionName: status.versionName,
            latencyMs: Int(Date().timeIntervalSince(sentAt) * 1000)
        )
    }

    private static func readPacket(_ connection: TCPConnection) async throws -> [UInt8] {
        var length = 0
        var shift = 0
        for _ in 0..<5 {
            let byte = try await connection.readByte()
            if shift == 28 && byte & 0xF0 != 0 { throw MCProtocolError.badVarInt }
            length |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                guard length > 0, length <= 2_097_151 else {
                    throw MCProtocolError.badPacket(id: length)
                }
                return try await connection.readBytes(length)
            }
            shift += 7
        }
        throw MCProtocolError.badVarInt
    }

    private static func parseStatus(_ json: String) throws -> ServerStatus {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any]
        else { throw MCProtocolError.badStatusResponse }

        let motd = plainText(from: object["description"] ?? "")
            .replacingOccurrences(of: "\u{00A7}[0-9A-FK-ORa-fk-or]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let players = object["players"] as? [String: Any]
        let version = object["version"] as? [String: Any]

        return ServerStatus(
            motd: motd,
            playersOnline: players?["online"] as? Int ?? 0,
            playersMax: players?["max"] as? Int ?? 0,
            versionName: version?["name"] as? String ?? "unknown",
            latencyMs: nil
        )
    }

    private static func plainText(from component: Any) -> String {
        if let text = component as? String {
            return text
        }
        if let components = component as? [Any] {
            return components.map(plainText(from:)).joined()
        }
        if let object = component as? [String: Any] {
            let text = object["text"] as? String ?? object["translate"] as? String ?? ""
            let extra = (object["extra"] as? [Any] ?? []).map(plainText(from:)).joined()
            return text + extra
        }
        return ""
    }
}
