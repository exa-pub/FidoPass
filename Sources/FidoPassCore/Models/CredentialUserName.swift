import Foundation

/// The `user.name` of a credential, with FidoPass's own key material removed.
///
/// A portable account stores its exported master key in `user.name`
/// (`EnrollmentService.credentialName`), and credential management hands that field back
/// for a PIN alone — no touch. Rendering it verbatim would print a backup key on screen and
/// write it into any export, bypassing `BackupKeyView` and its warning entirely.
///
/// Redaction happens here, in the core, rather than in a view: this type is `Codable` and
/// the JSON export never passes through a view.
public enum CredentialUserName: Sendable, Hashable, Codable {
    case value(String)
    /// FidoPass portable key material. Deliberately carries no payload — not even a
    /// truncated one, since 32 bytes of base64 has no safe prefix.
    case portableKeyMaterialWithheld
    case none

    /// What to put on screen. Never the withheld material.
    public var display: String {
        switch self {
        case .value(let name): return name
        case .portableKeyMaterialWithheld: return "portable key material (withheld)"
        case .none: return "—"
        }
    }

    /// The underlying string, when there is one that is safe to reveal. `nil` for withheld
    /// material, so a caller cannot reach it by accident.
    public var revealed: String? {
        if case .value(let name) = self { return name }
        return nil
    }

    /// Classifies a raw `user.name` read off an authenticator.
    ///
    /// Redaction is keyed on the relying party, not on the shape of the string: a foreign
    /// service whose user name merely looks like base64 is not FidoPass key material, and
    /// hiding it would misrepresent what is on the key.
    public static func classify(rawName: String?, rpId: String) -> CredentialUserName {
        guard let rawName, !rawName.isEmpty else { return .none }
        if rpId == AccountKind.portable.rpId, PortablePayload(base64: rawName) != nil {
            return .portableKeyMaterialWithheld
        }
        return .value(rawName)
    }
}
