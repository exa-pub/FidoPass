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
    /// One queue per worker, and one worker per application — `AppContainer` builds exactly
    /// one and hands it to every store, which is what makes the serialisation a fact rather
    /// than a convention.
    private let queue = KeyAccessQueue()

    init(backend: KeyBackend) {
        self.backend = backend
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (KeyBackend) throws -> T) async throws -> T {
        let backend = self.backend
        return try await queue.run { try body(backend) }
    }
}
