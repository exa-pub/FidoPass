import Foundation

/// Bounds CPU-heavy message work across windows. Cancelled queued edits never start; a
/// running cryptographic call completes, and its caller checks the input revision.
actor MessageCryptoWorker {
    static let shared = MessageCryptoWorker()
    func run<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try body()
    }
    func result<T: Sendable>(_ body: @Sendable () throws -> T) -> Result<T, Error> {
        Result { try run(body) }
    }
}
