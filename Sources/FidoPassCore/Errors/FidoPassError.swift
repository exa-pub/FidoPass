import Foundation

public enum FidoPassError: Error, LocalizedError {
    case libfido2(String)
    case noDevices
    case unsupported(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .libfido2(let message):
            return message
        case .noDevices:
            return "No FIDO devices found"
        case .unsupported(let feature):
            return "Unsupported feature: \(feature)"
        case .invalidState(let reason):
            return reason
        }
    }
}
