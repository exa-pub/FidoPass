import Foundation
import CLibfido2

/// libfido2 status codes the app needs to distinguish, as a Swift type.
///
/// The UI must react differently to "wrong PIN" than to "key locked forever", but it may
/// not `import CLibfido2` to compare raw constants — that would drag C types across the
/// module boundary. Translating once, here, keeps the boundary intact.
public enum FidoStatus: Equatable, Sendable {
    case pinInvalid
    case pinBlocked
    case pinAuthBlocked
    case pinRequired
    case pinNotSet
    case noCredentials
    case actionTimeout
    case userPresenceRequired
    case keyStoreFull
    case unsupportedOption
    case unsupportedExtension
    case invalidCommand
    case operationDenied
    case invalidLength
    case other(Int32)

    init(code: Int32) {
        switch code {
        case FIDO_ERR_PIN_INVALID:           self = .pinInvalid
        case FIDO_ERR_PIN_BLOCKED:           self = .pinBlocked
        case FIDO_ERR_PIN_AUTH_BLOCKED:      self = .pinAuthBlocked
        case FIDO_ERR_PIN_REQUIRED:          self = .pinRequired
        case FIDO_ERR_PIN_NOT_SET:           self = .pinNotSet
        case FIDO_ERR_NO_CREDENTIALS:        self = .noCredentials
        case FIDO_ERR_ACTION_TIMEOUT:        self = .actionTimeout
        case FIDO_ERR_UP_REQUIRED:           self = .userPresenceRequired
        case FIDO_ERR_KEY_STORE_FULL:        self = .keyStoreFull
        case FIDO_ERR_UNSUPPORTED_OPTION:    self = .unsupportedOption
        case FIDO_ERR_UNSUPPORTED_EXTENSION: self = .unsupportedExtension
        case FIDO_ERR_INVALID_COMMAND:       self = .invalidCommand
        case FIDO_ERR_OPERATION_DENIED:      self = .operationDenied
        case FIDO_ERR_INVALID_LENGTH:        self = .invalidLength
        default:                             self = .other(code)
        }
    }
}
