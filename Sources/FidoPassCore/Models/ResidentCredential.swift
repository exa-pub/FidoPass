import Foundation

/// Discoverable credential returned by credman. Unreported fields stay absent;
/// libfido2’s default zero counters/AAGUID are not authenticator-reported values.
public struct ResidentCredential: Sendable, Hashable, Codable, Identifiable {
    /// Taken from the enumeration loop, never from `fido_cred_rp_id`: that getter returns
    /// NULL for a credential obtained through credential management.
    public let rpId: String
    public let credentialIdB64: String
    /// `user.id` is opaque bytes, so hex is the only always-correct rendering.
    public let userIdHex: String
    /// User-id bytes as text when `readableText(from:)` accepts them. A v2 FidoPass
    /// identity is binary and need not be readable.
    public let userIdUTF8: String?
    public let userName: CredentialUserName
    public let userDisplayName: String?
    public let coseAlgorithm: Int?
    public let publicKeyB64: String?
    public let credentialProtection: CredentialProtection?
    /// Presence of a largeBlobKey. Its bytes remain in Core and must not enter exports.
    public let hasLargeBlobKey: Bool
    /// The state of a v2 FidoPass account's record in the large-blob store. `nil` for every
    /// other credential. The record's mask is never carried here: it is key material in the
    /// same sense as the withheld v1 name.
    public let record: RecordState?

    /// What the inventory found in the large-blob store for a v2 account.
    public enum RecordState: String, Sendable, Hashable, Codable {
        case local
        case portable
        case missing
        case corrupt
    }

    public var id: String { credentialIdB64 }

    /// Shows user-id bytes as text only when valid UTF-8 contains no control characters.
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
                hasLargeBlobKey: Bool,
                record: RecordState? = nil) {
        self.rpId = rpId
        self.credentialIdB64 = credentialIdB64
        self.userIdHex = userIdHex
        self.userIdUTF8 = userIdUTF8
        self.userName = userName.revealed.map { CredentialUserName.classify(rawName: $0, rpId: rpId) } ?? userName
        self.userDisplayName = CredentialUserName.classify(rawName: userDisplayName, rpId: rpId).revealed
        self.coseAlgorithm = coseAlgorithm
        self.publicKeyB64 = publicKeyB64
        self.credentialProtection = credentialProtection
        self.hasLargeBlobKey = hasLargeBlobKey
        self.record = record
    }

    /// Whether this credential belongs to FidoPass itself.
    ///
    /// Used only to offer the proper screen for it — never to filter the list. The manager
    /// shows the key as it is, and hiding the app's own credentials would make it lie by
    /// omission.
    public var isFidoPassCredential: Bool { AccountFormat.parse(rpId: rpId) != nil }

    /// The layout this credential is in, if it is FidoPass's.
    public var accountFormat: AccountFormat? { AccountFormat.parse(rpId: rpId)?.format }

    /// The kind of FidoPass account this is: from the relying party for v1, from the record
    /// for v2. `nil` for a foreign credential, and for a v2 credential without a record.
    public var accountKind: AccountKind? {
        guard let parsed = AccountFormat.parse(rpId: rpId) else { return nil }
        if let kind = parsed.kind { return kind }
        switch record {
        case .local: return .local
        case .portable: return .portable
        case .missing, .corrupt, nil: return nil
        }
    }

    /// The identity of the FidoPass account this credential is, if it is one: `user.id` for
    /// v2, derived from the credential id for a local v1 account. `nil` for a foreign
    /// credential — and for a portable v1 account, which `needsMigration` says outright.
    public var accountIdentity: AccountIdentity? {
        switch AccountFormat.parse(rpId: rpId) {
        case (.v2, _)?:
            return AccountIdentity(hex: userIdHex)
        case (.v1, .local?)?:
            return Data(base64Encoded: credentialIdB64).map(AccountIdentity.derived(fromCredentialId:))
        case (.v1, _)?, nil:
            return nil
        }
    }

    /// A FidoPass portable account in the v1 layout: migration reproduces it as v2.
    public var needsMigration: Bool {
        if case .portableKeyMaterialWithheld = userName { return true }
        return false
    }

    /// The best short label for a list row.
    public var listLabel: String {
        if let display = userDisplayName, !display.isEmpty { return display }
        if let name = userName.revealed, !name.isEmpty { return name }
        if let utf8 = userIdUTF8, !utf8.isEmpty { return utf8 }
        return String(credentialIdB64.prefix(12))
    }
}
