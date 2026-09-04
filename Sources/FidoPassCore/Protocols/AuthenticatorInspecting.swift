import Foundation

/// Read-only authenticator inspection; no operation requires touch.
public protocol AuthenticatorInspecting: Sendable {
    /// Everything the key says about itself. One open, no PIN, no touch.
    ///
    /// It does **open** the device, which on macOS seizes it away from every other process,
    /// so this may only run because a person asked — never because a key appeared.
    func inspect(devicePath: String) throws -> AuthenticatorInfo

    /// Reads discoverable credentials with a PIN in one open. Unsupported credential
    /// management throws rather than appearing as an empty inventory.
    func inventory(devicePath: String, pin: String) throws -> CredentialInventory
}
