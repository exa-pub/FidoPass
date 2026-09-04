import Foundation

package enum TestTransportError: Error {
    case helperMissing
    case disconnected
    case busy
    case protocolViolation
    case deadlineExceeded
}
