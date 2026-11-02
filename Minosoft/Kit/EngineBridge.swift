import Foundation

/// The Swift side of MinosoftKit. The real implementation arrives when the
/// Kotlin/Native framework is linked; `MockEngineBridge` keeps the whole shell
/// exercisable until then.
protocol EngineBridge: AnyObject {
    /// Immutable world snapshots, produced on the engine thread.
    var worldState: AsyncStream<WorldSnapshot> { get }

    /// The block world the renderer draws. Nil until a session has one.
    var world: VoxelWorld? { get }

    /// Kane's session: Microsoft OAuth (Keychain-backed) + 1.20.4 login.
    func connect(to server: ServerAddress, account: Account) async throws

    /// Input flows back into Sable's simulation through here only.
    func handle(_ event: InputEvent)

    func disconnect()
}

/// Mock engine: simulates a ticking world so the Eros flow, Metal view,
/// touch controls and HUD can be developed before the Kotlin core lands.
final class MockEngineBridge: EngineBridge {
    private var continuation: AsyncStream<WorldSnapshot>.Continuation?
    private var timer: Timer?
    private var tick = 0
    private var position = SIMD3<Float>(0, 64, 0)
    private var yaw: Float = 0
    private var move = JoystickVector()
    private var state = ConnectionState.connecting

    var world: VoxelWorld? { nil }

    var worldState: AsyncStream<WorldSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.stopTicking()
            }
        }
    }

    func connect(to server: ServerAddress, account: Account) async throws {
        state = .authenticating
        try await Task.sleep(nanoseconds: 400_000_000)
        state = .loggingIn
        try await Task.sleep(nanoseconds: 400_000_000)
        state = .playing
        startTicking()
    }

    func handle(_ event: InputEvent) {
        switch event {
        case .move(let vector):
            move = vector
        case .look(let delta):
            yaw += Float(delta.width) * 0.25
        case .primaryAction, .secondaryAction, .chat, .pauseToggle:
            break // wired to the real engine with the MinosoftKit milestone
        }
    }

    func disconnect() {
        stopTicking()
        state = .disconnected
        continuation?.finish()
    }

    private func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tickSimulation()
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tickSimulation() {
        tick += 1
        let speed: Float = 0.05
        position.x += move.dx * speed
        position.z -= move.dy * speed
        yaw += 0.05
        let snapshot = WorldSnapshot(
            tick: tick,
            playerPosition: position,
            playerYaw: yaw,
            playerPitch: 0,
            loadedChunkCount: 9,
            state: state,
            debugMessage: "Mock engine — MinosoftKit core not linked yet"
        )
        continuation?.yield(snapshot)
    }
}