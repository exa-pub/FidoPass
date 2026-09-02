import Foundation

/// How much user verification a credential demands, as CTAP's `credProtect` extension.
public enum CredentialProtection: Int, Sendable, Hashable, Codable, CaseIterable {
    /// The authenticator's default when nothing was requested.
    case uvOptional = 1
    case uvOptionalWithCredentialID = 2
    case uvRequired = 3

    public var summary: String {
        switch self {
        case .uvOptional: return "1 — user verification optional"
        case .uvOptionalWithCredentialID: return "2 — optional with credential id"
        case .uvRequired: return "3 — user verification required"
        }
    }
}

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

/// One resident (discoverable) credential, exactly as credential management reports it.
///
/// The fields CTAP does not return for an enumerated credential are absent here rather than
/// zero. `fido_cred_sigcount` answers 0 and `fido_cred_aaguid_len` answers 16 zero bytes for
/// a credential read this way; both are artefacts of the C struct, not values, and
/// rendering either would be a lie.
public struct ResidentCredential: Sendable, Hashable, Codable, Identifiable {
    /// Taken from the enumeration loop, never from `fido_cred_rp_id`: that getter returns
    /// NULL for a credential obtained through credential management.
    public let rpId: String
    public let credentialIdB64: String
    /// `user.id` is opaque bytes, so hex is the only always-correct rendering.
    public let userIdHex: String
    /// The same bytes as readable text, when they are any — which they are for a FidoPass
    /// account, whose id is stored there directly. See `readableText(from:)` for why
    /// "decodes as UTF-8" is not the test.
    public let userIdUTF8: String?
    public let userName: CredentialUserName
    public let userDisplayName: String?
    public let coseAlgorithm: Int?
    public let publicKeyB64: String?
    public let credentialProtection: CredentialProtection?
    /// Whether a `largeBlobKey` came back with this credential.
    ///
    /// The key itself never leaves the core: it decrypts that credential's large blob. In
    /// practice authenticators return one for every resident credential, whether or not it
    /// was asked for at creation, so this carries little information — but it must still
    /// never be the material itself.
    public let hasLargeBlobKey: Bool

    public var id: String { credentialIdB64 }

    /// Renders opaque bytes as text only when the result is something a person can read.
    ///
    /// "Valid UTF-8" is not enough. A one-byte user id of `0x05` decodes perfectly well into
    /// a control character, which draws as nothing at all — so the manager would show an
    /// empty "user id (as text)" row and a blank list entry, both of which read as "this
    /// field is missing" rather than "these bytes are not text". Seen on real hardware.
    public static func readableText(from data: Data) -> String? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        let unreadable = text.unicodeScalars.contains { scalar in
            // Controls, and the format/unassigned classes that render as nothing.
            scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .unassigned
                || scalar.properties.generalCategory == .privateUse
                || scalar.properties.generalCategory == .surrogate
        }
        return unreadable ? nil : text
    }

    public init(rpId: String,
                credentialIdB64: String,
                userIdHex: String,
                userIdUTF8: String?,
                userName: CredentialUserName,
                userDisplayName: String?,
                coseAlgorithm: Int?,
                publicKeyB64: String?,
                credentialProtection: CredentialProtection?,
                hasLargeBlobKey: Bool) {
        self.rpId = rpId
        self.credentialIdB64 = credentialIdB64
        self.userIdHex = userIdHex
        self.userIdUTF8 = userIdUTF8
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.coseAlgorithm = coseAlgorithm
        self.publicKeyB64 = publicKeyB64
        self.credentialProtection = credentialProtection
        self.hasLargeBlobKey = hasLargeBlobKey
    }

    /// Whether this credential belongs to FidoPass itself.
    ///
    /// Used only to offer the proper screen for it — never to filter the list. The manager
    /// shows the key as it is, and hiding the app's own credentials would make it lie by
    /// omission.
    public var isFidoPassCredential: Bool { AccountKind(rpId: rpId) != nil }

    /// The best short label for a list row.
    public var listLabel: String {
        if let display = userDisplayName, !display.isEmpty { return display }
        if let name = userName.revealed, !name.isEmpty { return name }
        if let utf8 = userIdUTF8, !utf8.isEmpty { return utf8 }
        return String(credentialIdB64.prefix(12))
    }
}
