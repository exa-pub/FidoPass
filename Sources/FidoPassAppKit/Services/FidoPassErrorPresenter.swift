import Foundation
import FidoPassCore

/// Maps core errors to actionable presentation, retaining raw details for diagnostics.
enum FidoPassErrorPresenter {

    static func message(for error: Error) -> PresentedError {
        if let mutation = error as? KeyMutationError {
            var result = message(for: mutation.underlying)
            result = PresentedError(kind: result.kind, title: mutation.localizedDescription,
                                    recovery: result.title, details: result.details)
            return result
        }
        if let fidoError = error as? FidoPassError {
            return message(for: fidoError)
        }
        return PresentedError(kind: .other,
                       title: error.localizedDescription,
                       recovery: nil,
                       details: nil)
    }

    private static func message(for error: FidoPassError) -> PresentedError {
        switch error {
        case .noDevices:
            return PresentedError(kind: .noDevices,
                           title: "No security key found",
                           recovery: "Connect your key and try again.",
                           details: error.errorDescription)

        case .unsupported(let feature):
            return PresentedError(kind: .unsupported,
                           title: "This key cannot be used",
                           recovery: feature,
                           details: error.errorDescription)

        case .invalidState(let reason):
            return PresentedError(kind: .other,
                           title: reason,
                           recovery: nil,
                           details: nil)

        case .libfido2(_, let status, _):
            return message(for: status, details: error.errorDescription)
        }
    }

    private static func message(for status: FidoStatus, details: String?) -> PresentedError {
        switch status {
        // Same consequence as a plain wrong PIN — an attempt is gone — so it is presented as
        // one. Keeping it a separate kind would only mean every caller counting attempts had
        // to learn about a second spelling of "wrong PIN".
        case .pinInvalid, .pinAuthInvalid:
            return PresentedError(kind: .pinInvalid,
                           title: "Incorrect PIN",
                           recovery: nil,
                           details: details)

        case .pinAuthBlocked:
            return PresentedError(kind: .pinAuthBlocked,
                           title: "Too many PIN attempts in a row",
                           recovery: "Unplug the key and plug it back in, then try again. Further wrong attempts can block the key, requiring a reset that erases its accounts.",
                           details: details)

        case .pinBlocked:
            return PresentedError(kind: .pinBlocked,
                           title: "This key is locked",
                           recovery: "The PIN has been entered incorrectly too many times. Only a full FIDO reset will make the key usable again, and that erases every account on it — including the keys derived from them.",
                           details: details)

        case .pinRequired, .pinNotSet:
            return PresentedError(kind: .pinRequired,
                           title: "This key has no PIN yet",
                           recovery: "Set a PIN on the key before enrolling accounts.",
                           details: details)

        case .pinPolicyViolation:
            return PresentedError(kind: .pinRejectedByKey,
                           title: "The key will not accept that PIN",
                           recovery: "Choose a different one — longer, and not a run of repeated or consecutive digits. No PIN attempt was used.",
                           details: details)

        case .notAllowed:
            return PresentedError(kind: .notAllowed,
                           title: "The key refused the request",
                           recovery: "It allows this only in a particular state, and it is not in that state now.",
                           details: details)

        case .noCredentials:
            return PresentedError(kind: .noCredentials,
                           title: "No accounts on this key",
                           recovery: nil,
                           details: details)

        case .userActionTimeout:
            return PresentedError(kind: .touchTimeout,
                           title: "The key was not touched in time",
                           recovery: "The key was waiting for a finger and gave up. Try again and touch it as soon as it starts blinking.",
                           details: details)

        case .actionTimeout:
            return PresentedError(kind: .touchTimeout,
                           title: "The key was not touched in time",
                           recovery: "Try again and touch the key when it starts blinking.",
                           details: details)

        case .userPresenceRequired:
            return PresentedError(kind: .touchRequired,
                           title: "The key needs to be touched",
                           recovery: "Try again and touch the key when it starts blinking.",
                           details: details)

        case .keyStoreFull:
            return PresentedError(kind: .storageFull,
                           title: "No free slots left on this key",
                           recovery: "Delete an account you no longer need, or use another key.",
                           details: details)

        case .unsupportedOption, .unsupportedExtension, .invalidCommand:
            return PresentedError(kind: .unsupported,
                           title: "This key does not support the operation",
                           recovery: "FidoPass needs a CTAP2 key with the hmac-secret extension.",
                           details: details)

        case .operationDenied:
            return PresentedError(kind: .operationDenied,
                           title: "The key refused the request",
                           recovery: "Touch the key — or place your finger on it — when it starts blinking, then try again.",
                           details: details)

        case .invalidLength:
            return PresentedError(kind: .malformedRequest,
                           title: "The request was rejected before it reached the key",
                           recovery: "This is a bug in FidoPass rather than a problem with your key. The details below identify it.",
                           details: details)

        case .other:
            return PresentedError(kind: .other,
                           title: "The security key reported an error",
                           recovery: nil,
                           details: details)
        }
    }
}
