import Foundation

/// Wide, read-only interrogation of an authenticator.
///
/// Separate from `DeviceRepositoryProtocol`, which is device *access* — open, list, read the
/// small status the HUD routes on. This is the reading done because a person asked to look,
/// and it is behind a protocol for the usual reason: CI has no authenticator.
///
/// Nothing here writes to the key, and nothing here needs a touch.
public protocol AuthenticatorInspecting: Sendable {
    /// Everything the key says about itself. One open, no PIN, no touch.
    ///
    /// It does **open** the device, which on macOS seizes it away from every other process,
    /// so this may only run because a person asked — never because a key appeared.
    func inspect(devicePath: String) throws -> AuthenticatorInfo

    /// Every resident credential on the key, grouped by relying party.
    ///
    /// Needs the PIN (credential-management permission) and no touch. One open covers the
    /// whole read — metadata, the relying-party list and each party's credentials — because
    /// opening once per relying party would seize and release the key N times.
    ///
    /// A key that cannot do credential management throws `.unsupported` rather than
    /// returning an empty inventory: "this key holds nothing" and "this key cannot be asked"
    /// must not look the same.
    func inventory(devicePath: String, pin: String) throws -> CredentialInventory
}
