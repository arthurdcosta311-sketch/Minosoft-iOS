import Foundation
import Network

/// Kane's slice: the iOS transport under the session code.
/// Desktop Minosoft speaks over JVM sockets; on iOS the session rides on this instead.
/// Async/await wrapper around Network.framework's NWConnection, one continuation per operation.
final class TCPConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "de.bixilon.minosoft.tcp")

    init?(host: String, port: UInt16) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    func connect(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ContinuationGuard(continuation)
            let timeoutWork = DispatchWorkItem { once.resume(throwing: MCProtocolError.timeout) }
            once.onResume = { timeoutWork.cancel() }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume()
                case .failed(let error):
                    once.resume(throwing: error)
                case .cancelled:
                    once.resume(throwing: MCProtocolError.connectionClosed)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            connection.start(queue: queue)
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(maximumLength: Int = 65536) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    // Empty data with no error means the peer closed (isComplete or otherwise).
                    continuation.resume(throwing: MCProtocolError.connectionClosed)
                }
            }
        }
    }

    /// Reads exactly one byte — the primitive VarInt decoding on the wire needs.
    func readByte() async throws -> UInt8 {
        let data = try await receive(maximumLength: 1)
        return data[data.startIndex]
    }

    /// Reads exactly `count` bytes, accumulating across as many receives as it takes.
    func readBytes(_ count: Int) async throws -> [UInt8] {
        var collected = [UInt8]()
        collected.reserveCapacity(count)
        while collected.count < count {
            let data = try await receive(maximumLength: count - collected.count)
            collected.append(contentsOf: data)
        }
        return collected
    }

    func close() {
        connection.cancel()
    }
}

/// Makes sure a continuation is resumed exactly once, no matter which callback fires first.
final class ContinuationGuard {
    private let lock = NSLock()
    private var hasResumed = false
    private let continuation: CheckedContinuation<Void, Error>
    var onResume: (() -> Void)?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        finish { $0.resume() }
    }

    func resume(throwing error: Error) {
        finish { $0.resume(throwing: error) }
    }

    private func finish(_ body: (CheckedContinuation<Void, Error>) -> Void) {
        lock.lock()
        let first = !hasResumed
        hasResumed = true
        let callback = onResume
        lock.unlock()
        guard first else { return }
        callback?()
        body(continuation)
    }
}