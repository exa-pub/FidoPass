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
    /// Free resident-credential slots, when the authenticator reports them.
    public var remainingResidentKeys: Int?

    public init(pinRetriesRemaining: Int?,
                hasPIN: Bool,
                supportsHmacSecret: Bool,
                remainingResidentKeys: Int?) {
        self.pinRetriesRemaining = pinRetriesRemaining
        self.hasPIN = hasPIN
        self.supportsHmacSecret = supportsHmacSecret
        self.remainingResidentKeys = remainingResidentKeys
    }
}
