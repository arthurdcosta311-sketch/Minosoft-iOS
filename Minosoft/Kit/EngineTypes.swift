import Foundation

// Shared value types crossing the Swift ↔ engine boundary.
// Once the MinosoftKit framework (compiled from minosoft-core) is linked,
// these mirror the Kotlin snapshot/event API one to one.

struct Account: Identifiable, Hashable {
    /// The local name, or — for a signed-in account — the Minecraft profile name.
    let id = UUID()
    var username: String
    var kind: Kind = .offline
    /// The profile UUID an online-mode server checks the session server against.
    var uuid: UUID?
    /// The tokens that prove this profile to Mojang and the session server.
    var session: MicrosoftSession?

    enum Kind: String {
        case microsoft
        case offline
    }

    /// The account a server sees: an offline name, or a Minecraft profile
    /// backed by Microsoft sign-in.
    static func microsoft(_ account: SignedInAccount) -> Account {
        Account(username: account.name, kind: .microsoft, uuid: account.uuid, session: account.session)
    }

    /// The Keychain-shaped view of this account, when it is a signed-in one.
    var signedIn: SignedInAccount? {
        guard kind == .microsoft, let uuid, let session else { return nil }
        return SignedInAccount(uuid: uuid, name: username, session: session)
    }
}

struct ServerAddress: Hashable {
    var host: String
    var port: Int = 25565
}

struct ServerEntry: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var address: ServerAddress
    var motd: String = "…"
    var playersOnline: Int = 0
    var playerCap: Int = 0
    var status: Status = .unknown

    enum Status: String {
        case unknown
        case online
        case offline
    }
}

struct JoystickVector: Equatable {
    var dx: Float = 0
    var dy: Float = 0
}

enum InputEvent {
    case move(JoystickVector)   // virtual stick, normalised to unit circle
    case look(CGSize)           // drag delta in points
    case primaryAction          // tap to break
    case secondaryAction        // long-press to place
    case chat(String)
    case pauseToggle
}

enum ConnectionState: String {
    case connecting
    case authenticating
    case loggingIn
    case playing
    case disconnected
}

// Sable's threading contract: Swift only ever consumes immutable snapshots.
struct WorldSnapshot {
    var tick: Int = 0
    var playerPosition: SIMD3<Float> = SIMD3(0, 64, 0)
    var playerYaw: Float = 0
    var playerPitch: Float = 0
    var loadedChunkCount: Int = 0
    var state: ConnectionState = .connecting
    var debugMessage: String = ""
    /// The most recent chat lines, newest last.
    var chatLines: [String] = []

    static let initial = WorldSnapshot(state: .connecting)
}