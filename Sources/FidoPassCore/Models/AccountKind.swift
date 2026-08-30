import Foundation

/// How a credential's derivation material is bound to the authenticator.
///
/// The raw values are the WebAuthn relying-party ids the credentials are enrolled under,
/// and they take part in salt derivation — renaming one changes every password issued for
/// that kind, so they are frozen.
public enum AccountKind: String, Codable, Hashable, CaseIterable, Sendable {
    /// Derivation material never leaves this authenticator.
    case local
    /// Derivation material can be exported and re-imported onto another authenticator, so
    /// the same passwords survive losing a key.
    case portable

    public var rpId: String {
        switch self {
        case .local: return "fidopass.local"
        case .portable: return "fidopass.portable"
        }
    }

    public init?(rpId: String) {
        guard let match = AccountKind.allCases.first(where: { $0.rpId == rpId }) else { return nil }
        self = match
    }
}
