@preconcurrency import FidoPassCore
import Foundation

/// Runs backend work off the main actor, one operation at a time.
///
/// libfido2 calls block for as long as the user takes to touch the key — seconds, sometimes
/// tens of them. Wrapping them here keeps that fact in one place instead of scattering
/// `Task.detached` through the stores, and routing every one through `KeyAccessQueue` keeps
/// two windows from reaching for the same key at once.
struct KeyWorker: Sendable {
    let backend: KeyBackend

    init(backend: KeyBackend) {
        self.backend = backend
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (KeyBackend) throws -> T) async throws -> T {
        let backend = self.backend
        return try await KeyAccessQueue.shared.run { try body(backend) }
    }
}
