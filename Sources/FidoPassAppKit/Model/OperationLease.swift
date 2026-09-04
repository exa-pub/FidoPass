import Foundation

/// The lock protects validity across the main actor and the serial hardware queue.
final class OperationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.withLock { valid = false } }
    var isValid: Bool { lock.withLock { valid } }
    func check() throws { if !isValid { throw CancellationError() } }
}
