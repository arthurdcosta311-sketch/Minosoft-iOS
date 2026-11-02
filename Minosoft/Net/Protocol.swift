import Foundation

/// Kane's slice: the protocol constants and packet ids we speak.
///
/// The number and every id below come from Minosoft's own
/// `resources/assets/minosoft/mapping/versions.json`, entry `924` (the packet
/// table 1.20.4 / PVN 931 reuses). The list order there *is* the wire order, so
/// ids are indices. 1.7–1.20.3 compatibility is a follow-on: this build talks
/// 1.20.4 only, exactly like the other hundred-and-something packet ids it does
/// not implement yet.
enum Protocol {
    static let number = 765
    static let name = "1.20.4"
    static let maxPacketLength = 2_097_151
}

enum HandshakePacket {
    static let id: Int = 0x00
    static let nextStateStatus: Int = 1
    static let nextStateLogin: Int = 2
}

enum LoginPacket {
    enum C2S {
        static let start: Int = 0x00
        static let encryption: Int = 0x01
        static let loginPluginResponse: Int = 0x02
        static let loginAcknowledged: Int = 0x03
    }
    enum S2C {
        static let disconnect: Int = 0x00
        static let encryptionRequest: Int = 0x01
        static let success: Int = 0x02
        static let compression: Int = 0x03
        static let loginPluginRequest: Int = 0x04
    }
}

enum ConfigurationPacket {
    enum C2S {
        static let settings: Int = 0x00
        static let ready: Int = 0x02
        static let keepAlive: Int = 0x03
        static let pong: Int = 0x04
    }
    enum S2C {
        static let disconnect: Int = 0x01
        static let finishConfiguration: Int = 0x02
        static let keepAlive: Int = 0x03
        static let ping: Int = 0x04
        static let registries: Int = 0x05
        static let features: Int = 0x08
    }
}

enum PlayPacket {
    enum C2S {
        static let confirmTeleport: Int = 0x00
        static let chatMessage: Int = 0x05
        static let chunkBatchReceived: Int = 0x07
        static let keepAlive: Int = 0x15
        static let setPlayerPositionAndRotation: Int = 0x18
        static let playerAction: Int = 0x21
        static let pong: Int = 0x24
        static let swingArm: Int = 0x33
        static let interactBlock: Int = 0x35
    }
    enum S2C {
        static let blockUpdate: Int = 0x09
        static let chunkBatchFinished: Int = 0x0C
        static let chunkBatchStart: Int = 0x0D
        static let disconnect: Int = 0x1B
        static let unloadChunk: Int = 0x1F
        static let gameEvent: Int = 0x20
        static let keepAlive: Int = 0x24
        static let chunkData: Int = 0x25
        static let worldEvent: Int = 0x26
        static let updateLight: Int = 0x28
        static let joinGame: Int = 0x29
        static let ping: Int = 0x33
        static let pong: Int = 0x34
        static let playerPosition: Int = 0x3E
        static let teleport: Int = 0x6D
        static let sectionBlocks: Int = 0x47
        static let health: Int = 0x5B
        static let systemChat: Int = 0x69
    }
}

/// Vanilla block faces, in the protocol's own order.
enum BlockFace {
    static let down = 0
    static let up = 1
    static let north = 2
    static let south = 3
    static let west = 4
    static let east = 5
}

/// Player action ids for `PlayPacket.C2S.playerAction`.
enum PlayerAction {
    static let startDestroyBlock = 0
    static let stopDestroyBlock = 2
}
