import Foundation

/// Never spend another PIN attempt after authentication failed, or after an unknown
/// transport outcome. Cleanup is safe only when the key returned a definite other error.
public enum KeyFailurePolicy {
    public static func status(of error: any Error) -> FidoStatus? {
        if let mutation = error as? KeyMutationError { return status(of: mutation.underlying) }
        return (error as? FidoPassError)?.status
    }

    public static func invalidatesPINSession(_ error: any Error) -> Bool {
        [.pinInvalid, .pinAuthInvalid, .pinBlocked, .pinAuthBlocked, .pinRequired, .pinNotSet].contains(status(of: error))
    }

    public static func allowsAuthenticatedRecovery(after error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let status = status(of: error) else { return true }
        switch status {
        case .pinInvalid, .pinAuthInvalid, .pinBlocked, .pinAuthBlocked, .pinRequired,
             .pinNotSet, .pinPolicyViolation, .actionTimeout, .userActionTimeout, .other:
            return false
        default: return true
        }
    }
}
