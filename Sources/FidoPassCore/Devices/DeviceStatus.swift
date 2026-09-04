import Foundation

/// What the app can learn about an authenticator without asking the user to touch it.
public struct DeviceStatus: Hashable, Sendable {
    /// PIN attempts left before the authenticator locks itself permanently.
    ///
    /// `nil` when the authenticator declines to report it. Eight is the usual maximum;
    /// three consecutive failures already force a reconnect.
    public var pinRetriesRemaining: Int?
    /// Whether a PIN has been configured at all. Enrolment cannot proceed without one.
    public var hasPIN: Bool
    /// Whether the authenticator supports the extension every derived password depends on.
    public var supportsHmacSecret: Bool
    /// Whether the authenticator has a large-blob store. Every v2 account keeps its record
    /// there, so a key without one can hold no new account — only what is already on it.
    public var supportsLargeBlobs: Bool
    /// Free resident-credential slots, when the authenticator reports them.
    public var remainingResidentKeys: Int?
    /// Shortest PIN this key will accept, when it says. CTAP2 floors it at 4, but a key may
    /// raise it — and one that does will reject a PIN this app would otherwise have allowed.
    public var minPINLength: Int?
    /// The key insists the PIN be changed before it will do anything else.
    public var forcePINChange: Bool
    /// Identifies the authenticator's make and model — deliberately not the individual key.
    ///
    /// WebAuthn requires an AAGUID to be shared by at least 100 000 devices, precisely so it
    /// cannot be used to recognise a person. Useful as a *negative* check — a different
    /// AAGUID is certainly a different key — and never as a positive one.
    public var aaguid: String?

    public init(pinRetriesRemaining: Int?,
                hasPIN: Bool,
                supportsHmacSecret: Bool,
                supportsLargeBlobs: Bool = false,
                remainingResidentKeys: Int?,
                minPINLength: Int? = nil,
                forcePINChange: Bool = false,
                aaguid: String? = nil) {
        self.pinRetriesRemaining = pinRetriesRemaining
        self.hasPIN = hasPIN
        self.supportsHmacSecret = supportsHmacSecret
        self.supportsLargeBlobs = supportsLargeBlobs
        self.remainingResidentKeys = remainingResidentKeys
        self.minPINLength = minPINLength
        self.forcePINChange = forcePINChange
        self.aaguid = aaguid
    }

    /// The PIN rules to enforce in the UI for this key.
    public var pinPolicy: PinPolicy {
        PinPolicy(minimumCodePoints: minPINLength ?? PinPolicy.ctapFloor)
    }
}
