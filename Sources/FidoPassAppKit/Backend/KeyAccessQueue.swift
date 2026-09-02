@preconcurrency import FidoPassCore
import Foundation

/// The one thread on which the authenticator is spoken to.
///
/// A security key is exclusive: opening it seizes the device, and two overlapping operations
/// mean one of them fails for a reason that has nothing to do with what the user did. That
/// could not happen while the panel was the only caller — a panel does one thing at a time —
/// but the manager window can now read a key while the panel is generating a password from
/// it, so the ordering has to be made explicit rather than left to the UI's shape.
///
/// A serial queue rather than an actor: the work is a blocking C call, and an actor that
/// awaited it would suspend and let the next caller straight in, which is precisely what
/// must not happen.
final class KeyAccessQueue: @unchecked Sendable {
    static let shared = KeyAccessQueue()

    private let queue = DispatchQueue(label: "com.fidopass.keyAccess", qos: .userInitiated)

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
