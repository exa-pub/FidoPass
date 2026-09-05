import Foundation

package enum VirtualKeyError: Error, LocalizedError, Sendable {
    case helperMissing
    case disconnected
    case busy
    case protocolViolation
    case deadlineExceeded

    package var errorDescription: String? {
        switch self {
        case .helperMissing: "The OpenSK helper is missing or is not executable. Rebuild the app with --virtual-keys."
        case .disconnected: "The virtual key stopped or was disconnected."
        case .busy: "The virtual key is busy."
        case .protocolViolation: "The OpenSK helper returned an invalid response. Rebuild the helper and app together."
        case .deadlineExceeded: "The OpenSK helper did not respond in time."
        }
    }
}
