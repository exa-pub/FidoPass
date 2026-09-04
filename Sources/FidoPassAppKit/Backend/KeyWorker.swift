import FidoPassCore
import Foundation

/// Runs blocking backend calls on the shared serial key queue.
/// AppContainer creates one worker for all windows.
struct KeyWorker: Sendable {
    let backend: KeyBackend
    private let queue = KeyAccessQueue()

    init(backend: KeyBackend) {
        self.backend = backend
    }

    func device<T: Sendable>(validity: OperationLease? = nil, _ body: @escaping @Sendable (KeyDeviceBackend) throws -> T) async throws -> T {
        let backend = self.backend
        return try await queue.run(validity: validity) { try body(backend) }
    }

    func accounts<T: Sendable>(validity: OperationLease? = nil, _ body: @escaping @Sendable (KeyAccountBackend) throws -> T) async throws -> T {
        let backend = self.backend
        return try await queue.run(validity: validity) { try body(backend) }
    }

    func admin<T: Sendable>(validity: OperationLease? = nil, _ body: @escaping @Sendable (KeyAdminBackend) throws -> T) async throws -> T {
        let backend = self.backend
        return try await queue.run(validity: validity) { try body(backend) }
    }
}
