import Foundation

/// Discoverable credentials grouped by relying party. Non-resident credentials cannot
/// be enumerated; their credential IDs are held by relying parties.
public struct CredentialInventory: Sendable, Hashable, Codable {

    public struct RelyingParty: Sendable, Hashable, Codable, Identifiable {
        /// The relying-party id, e.g. `github.com`.
        public let id: String
        /// The relying-party name, when the authenticator kept one.
        ///
        /// In practice it is almost always absent: keys tested so far return no name even
        /// for credentials created with one, so the UI must not be built around it.
        public let name: String?
        /// SHA-256 of the rp id, as the authenticator reports it.
        public let idHashHex: String
        public let credentials: [ResidentCredential]

        public init(id: String, name: String?, idHashHex: String, credentials: [ResidentCredential]) {
            self.id = id
            self.name = name
            self.idHashHex = idHashHex
            self.credentials = credentials
        }
    }

    public let relyingParties: [RelyingParty]
    /// Resident slots in use across the whole key — including relying parties whose
    /// credentials could not be listed, so it can legitimately exceed the count below.
    public let residentKeysUsed: Int?
    public let residentKeysRemaining: Int?
    /// Size of the serialized large-blob array, when the key has the extension. Its contents
    /// are never read: they belong to whoever wrote them.
    public let largeBlobArrayBytes: Int?
    /// Relying parties whose credential list could not be read, with the reason. A partial
    /// inventory has to say so rather than look complete.
    public let unreadableRelyingParties: [String: String]

    public init(relyingParties: [RelyingParty],
                residentKeysUsed: Int?,
                residentKeysRemaining: Int?,
                largeBlobArrayBytes: Int?,
                unreadableRelyingParties: [String: String] = [:]) {
        self.relyingParties = relyingParties
        self.residentKeysUsed = residentKeysUsed
        self.residentKeysRemaining = residentKeysRemaining
        self.largeBlobArrayBytes = largeBlobArrayBytes
        self.unreadableRelyingParties = unreadableRelyingParties
    }

    public var credentialCount: Int {
        relyingParties.reduce(0) { $0 + $1.credentials.count }
    }

    public var allCredentials: [ResidentCredential] {
        relyingParties.flatMap(\.credentials)
    }

    /// The sentence that has to accompany any slot count shown to a user.
    public static let undiscoverableCaveat =
        "Only discoverable credentials are listed. Server-side credentials occupy no slot on the key and cannot be enumerated."
}
