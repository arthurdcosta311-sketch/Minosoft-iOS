import Foundation

/// Kane + Sable's slice: the first real engine bridge.
///
/// The session speaks protocol 765 (1.20.4) — handshake, compression, the
/// configuration handshake every 1.20.2+ server requires, then play:
/// keepalives, teleport confirmations, chat, 20 Hz movement. Sable's
/// world/physics and Nio's renderer grow behind this same EngineBridge
/// interface; Swift only ever consumes immutable snapshots.
final class RealEngineBridge: EngineBridge {
    private var session: MCSession?
    private var continuation: AsyncStream<WorldSnapshot>.Continuation?
    private var movementTask: Task<Void, Never>?

    private var state: ConnectionState = .connecting
    private var tick = 0
    private var position = SIMD3<Double>(0, 64, 0)
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var move = JoystickVector()
    private var chatLines: [String] = []

    /// The session's block world, once there is a session.
    var world: VoxelWorld? { session?.world }

    var worldState: AsyncStream<WorldSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.stopMovement()
            }
        }
    }

    func connect(to server: ServerAddress, account: Account) async throws {
        guard account.kind == .offline || account.signedIn != nil else {
            throw MCProtocolError.unsupported(
                "Sign in with a Microsoft account in Player settings to join online-mode servers, or join an offline-mode server (LAN worlds, local test servers) with a local player name."
            )
        }
        state = .authenticating
        yieldSnapshot()

        // An online identity goes stale while the server list sits open;
        // refreshing before the first packet is what keeps the join valid.
        var account = account
        if account.kind == .microsoft {
            account = try await MicrosoftAuth.refreshing(account)
            await AccountStore.shared.update(account)
        }

        let session = MCSession()
        self.session = session

        Task { [weak self] in
            for await event in session.events {
                self?.apply(event)
            }
        }

        try await session.connect(host: server.host, port: UInt16(server.port), account: account)
        state = .playing
        yieldSnapshot()
        startMovement()
    }

    func handle(_ event: InputEvent) {
        switch event {
        case .move(let vector):
            move = vector
        case .look(let delta):
            // The camera's forward is (sin yaw, ·, -cos yaw): dragging right
            // must increase yaw, otherwise look drifts the wrong way.
            yaw = (yaw + Float(delta.width) * 0.3).truncatingRemainder(dividingBy: 360)
            pitch = max(-90, min(90, pitch - Float(delta.height) * 0.3))
        case .primaryAction:
            session?.swingArm()
        case .secondaryAction:
            break // block use needs a raycast: Sable's interaction slice
        case .chat(let text):
            session?.sendChat(text)
        case .pauseToggle:
            break
        }
    }

    func disconnect() {
        stopMovement()
        session?.close()
        session = nil
        state = .disconnected
        yieldSnapshot()
        continuation?.finish()
    }

    private func apply(_ event: MCSession.SessionEvent) {
        switch event {
        case .state(let newState):
            state = newState
        case .chat(let line):
            chatLines.append(line)
            if chatLines.count > 8 {
                chatLines.removeFirst(chatLines.count - 8)
            }
        case .position(let newPosition, let newYaw, let newPitch):
            position = newPosition
            yaw = newYaw
            // The protocol's positive pitch looks down; the camera's looks up.
            pitch = -newPitch
        case .kicked(let reason):
            chatLines.append("« \(reason) »")
            state = .disconnected
            stopMovement()
        }
        yieldSnapshot()
    }

    /// The movement loop: 20 Hz position-and-rotation packets, Minecraft's tick.
    /// Sable's physics replaces the free-flight drift behind it.
    private func startMovement() {
        guard movementTask == nil else { return }
        movementTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, self.session != nil else { continue }
                self.stepMovement()
                self.yieldSnapshot()
            }
        }
    }

    private func stopMovement() {
        movementTask?.cancel()
        movementTask = nil
    }

    private func stepMovement() {
        let radians = Double(yaw) * .pi / 180
        // Matches the camera: forward = (sin yaw, -cos yaw), right = (cos yaw, sin yaw),
        // so pushing the stick right strafes right instead of left.
        let forward = SIMD2<Double>(sin(radians), -cos(radians))
        let right = SIMD2<Double>(cos(radians), sin(radians))
        let stick = SIMD2<Double>(Double(move.dx), Double(move.dy))
        let delta = forward * (-stick.y) + right * stick.x
        position.x += delta.x * 0.22
        position.z += delta.y * 0.22
        // Pitch goes back to the protocol's sign convention on the wire.
        session?.sendMovement(position: position, yaw: yaw, pitch: -pitch, onGround: true)
    }

    private func yieldSnapshot() {
        tick += 1
        let sections = session?.world.loadedSectionCount ?? 0
        let snapshot = WorldSnapshot(
            tick: tick,
            playerPosition: SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z)),
            playerYaw: yaw,
            playerPitch: pitch,
            loadedChunkCount: sections,
            state: state,
            debugMessage: "1.20.4 session: handshake ✓ compression ✓ configuration ✓ play",
            chatLines: chatLines
        )
        continuation?.yield(snapshot)
    }
}