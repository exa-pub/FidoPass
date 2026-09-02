import Foundation

/// A failure, in words a person can act on.
///
/// Stores keep one of these rather than a string: what to say depends on where it is shown
/// — the PIN screen adds the attempts left, the manager does not — so the rendering is the
/// view's job, and a test can ask what *kind* of failure it was instead of matching English.
struct PresentedError: Equatable {

    enum Kind: Equatable {
        case pinInvalid
        case pinBlocked
        case pinAuthBlocked
        case pinRequired
        /// The key threw out the PIN itself rather than failing to verify it. Carries the one
        /// fact the user needs: no attempt was spent.
        case pinRejectedByKey
        /// The key will not do this in its current state. What that means depends entirely on
        /// what was being attempted, so the caller supplies the sentence that follows.
        case notAllowed
        case noCredentials
        case touchTimeout
        case touchRequired
        case storageFull
        case unsupported
        case noDevices
        case operationDenied
        case malformedRequest
        case other
    }

    var kind: Kind
    var title: String
    var recovery: String?
    /// The raw status, kept for bug reports without being the first thing a user sees.
    var details: String?

    init(kind: Kind, title: String, recovery: String?, details: String?) {
        self.kind = kind
        self.title = title
        self.recovery = recovery
        self.details = details
    }

    /// The error as `FidoPassErrorPresenter` explains it.
    init(_ error: Error) {
        self = FidoPassErrorPresenter.message(for: error)
    }

    /// The error, with the meaning of a bare refusal supplied by the caller.
    ///
    /// `FIDO_ERR_NOT_ALLOWED` means "not in this state", and which state depends entirely on
    /// what was attempted — a PIN that already exists, a reset window that has closed. The
    /// status mapping cannot know that; the operation can.
    init(_ error: Error, meaningOfRefusal meaning: String) {
        let presented = FidoPassErrorPresenter.message(for: error)
        guard presented.kind == .notAllowed else {
            self = presented
            return
        }
        self.init(kind: .notAllowed, title: presented.title, recovery: meaning, details: presented.details)
    }

    /// A sentence of the app's own, not a status from the key.
    static func plain(_ text: String) -> PresentedError {
        PresentedError(kind: .other, title: text, recovery: nil, details: nil)
    }

    func fullText(retriesRemaining: Int? = nil, includeDetails: Bool = true) -> String {
        var parts = [title]
        if let retriesRemaining, kind == .pinInvalid {
            parts.append(Self.attemptsSentence(retriesRemaining))
        }
        if let recovery { parts.append(recovery) }
        // Without the raw status an unmapped failure reads as "something went wrong"
        // and cannot be diagnosed by anyone, including a developer reading a report.
        if includeDetails, let details, kind == .other || kind == .malformedRequest {
            parts.append("Details: \(details)")
        }
        return parts.joined(separator: "\n\n")
    }

    private static func attemptsSentence(_ remaining: Int) -> String {
        switch remaining {
        case 0:
            return "No attempts left — the key is now locked."
        case 1:
            return "1 attempt left. After that the key locks permanently and every account on it is lost."
        default:
            return "\(remaining) attempts left before the key locks permanently."
        }
    }
}
