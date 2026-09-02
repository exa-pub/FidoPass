import Foundation

/// The operation needs the key's PIN and the store does not hold one.
///
/// One type for every store: "locked" means the same thing whichever store noticed it, and
/// the sentence the user reads must not depend on which one did.
struct KeyLockedError: LocalizedError, Equatable {
    var errorDescription: String? { "The security key is locked. Enter its PIN and try again." }
}
