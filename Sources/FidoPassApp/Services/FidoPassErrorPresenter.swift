import Foundation
import FidoPassCore

/// Turns libfido2 status codes into something a person can act on.
///
/// Raw errors read like `dev_get_assert: FIDO_ERR_PIN_INVALID`, which says nothing about
/// what went wrong or what to do — and, for the PIN cases, hides that the authenticator is
/// counting down to a permanent lock-out. The raw text is kept as `details` so it stays
/// available for bug reports without being the first thing a user sees.
enum FidoPassErrorPresenter {

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

    struct Message {
        var kind: Kind
        var title: String
        var recovery: String?
        var details: String?
        var isRetryable: Bool

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

    static func message(for error: Error) -> Message {
        if let fidoError = error as? FidoPassError {
            return message(for: fidoError)
        }
        return Message(kind: .other,
                       title: error.localizedDescription,
                       recovery: nil,
                       details: nil,
                       isRetryable: false)
    }

    private static func message(for error: FidoPassError) -> Message {
        switch error {
        case .noDevices:
            return Message(kind: .noDevices,
                           title: "No security key found",
                           recovery: "Connect your key and try again.",
                           details: error.errorDescription,
                           isRetryable: true)

        case .unsupported(let feature):
            return Message(kind: .unsupported,
                           title: "This key cannot be used",
                           recovery: feature,
                           details: error.errorDescription,
                           isRetryable: false)

        case .invalidState(let reason):
            return Message(kind: .other,
                           title: reason,
                           recovery: nil,
                           details: nil,
                           isRetryable: false)

        case .libfido2(_, let status, _):
            return message(for: status, details: error.errorDescription)
        }
    }

    private static func message(for status: FidoStatus, details: String?) -> Message {
        switch status {
        // Same consequence as a plain wrong PIN — an attempt is gone — so it is presented as
        // one. Keeping it a separate kind would only mean every caller counting attempts had
        // to learn about a second spelling of "wrong PIN".
        case .pinInvalid, .pinAuthInvalid:
            return Message(kind: .pinInvalid,
                           title: "Incorrect PIN",
                           recovery: nil,
                           details: details,
                           isRetryable: true)

        case .pinAuthBlocked:
            return Message(kind: .pinAuthBlocked,
                           title: "Too many PIN attempts in a row",
                           recovery: "Unplug the key and plug it back in, then try again. One more wrong PIN after that may lock it for good.",
                           details: details,
                           isRetryable: false)

        case .pinBlocked:
            return Message(kind: .pinBlocked,
                           title: "This key is locked",
                           recovery: "The PIN has been entered incorrectly too many times. Only a full FIDO reset will make the key usable again, and that erases every account on it — including the keys derived from them.",
                           details: details,
                           isRetryable: false)

        case .pinRequired, .pinNotSet:
            return Message(kind: .pinRequired,
                           title: "This key has no PIN yet",
                           recovery: "Set a PIN on the key before enrolling accounts.",
                           details: details,
                           isRetryable: false)

        case .pinPolicyViolation:
            return Message(kind: .pinRejectedByKey,
                           title: "The key will not accept that PIN",
                           recovery: "Choose a different one — longer, and not a run of repeated or consecutive digits. No PIN attempt was used.",
                           details: details,
                           isRetryable: true)

        case .notAllowed:
            return Message(kind: .notAllowed,
                           title: "The key refused the request",
                           recovery: "It allows this only in a particular state, and it is not in that state now.",
                           details: details,
                           isRetryable: true)

        case .noCredentials:
            return Message(kind: .noCredentials,
                           title: "No accounts on this key",
                           recovery: nil,
                           details: details,
                           isRetryable: false)

        case .userActionTimeout:
            return Message(kind: .touchTimeout,
                           title: "The key was not touched in time",
                           recovery: "The key was waiting for a finger and gave up. Try again and touch it as soon as it starts blinking.",
                           details: details,
                           isRetryable: true)

        case .actionTimeout:
            return Message(kind: .touchTimeout,
                           title: "The key was not touched in time",
                           recovery: "Try again and touch the key when it starts blinking.",
                           details: details,
                           isRetryable: true)

        case .userPresenceRequired:
            return Message(kind: .touchRequired,
                           title: "The key needs to be touched",
                           recovery: "Try again and touch the key when it starts blinking.",
                           details: details,
                           isRetryable: true)

        case .keyStoreFull:
            return Message(kind: .storageFull,
                           title: "No free slots left on this key",
                           recovery: "Delete an account you no longer need, or use another key.",
                           details: details,
                           isRetryable: false)

        case .unsupportedOption, .unsupportedExtension, .invalidCommand:
            return Message(kind: .unsupported,
                           title: "This key does not support the operation",
                           recovery: "FidoPass needs a CTAP2 key with the hmac-secret extension.",
                           details: details,
                           isRetryable: false)

        case .operationDenied:
            return Message(kind: .operationDenied,
                           title: "The key refused the request",
                           recovery: "Touch the key — or place your finger on it — when it starts blinking, then try again.",
                           details: details,
                           isRetryable: true)

        case .invalidLength:
            return Message(kind: .malformedRequest,
                           title: "The request was rejected before it reached the key",
                           recovery: "This is a bug in FidoPass rather than a problem with your key. The details below identify it.",
                           details: details,
                           isRetryable: false)

        case .other:
            return Message(kind: .other,
                           title: "The security key reported an error",
                           recovery: nil,
                           details: details,
                           isRetryable: true)
        }
    }
}
