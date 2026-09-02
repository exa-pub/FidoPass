import Foundation

public enum FidoPassError: Error, LocalizedError, Sendable {
    /// A libfido2 call failed. The translated status travels with the message so the UI can
    /// react to specific conditions — running out of PIN attempts above all — instead of
    /// pattern-matching English text.
    case libfido2(operation: String, status: FidoStatus, message: String)
    case noDevices
    case unsupported(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .libfido2(let operation, _, let message):
            return "\(operation): \(message)"
        case .noDevices:
            return "No FIDO devices found"
        case .unsupported(let feature):
            return "Unsupported feature: \(feature)"
        case .invalidState(let reason):
            return reason
        }
    }

    public var status: FidoStatus? {
        guard case .libfido2(_, let status, _) = self else { return nil }
        return status
    }
}
