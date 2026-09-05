import Foundation

/// Authenticator PIN and reset operations, separate from credential management.
public protocol DeviceManaging: Sendable {
    /// Sets the very first PIN. The key refuses with `.notAllowed` if it already has one.
    func setInitialPIN(devicePath: String, newPIN: String) throws

    /// Replaces the PIN, proving knowledge of the old one.
    ///
    /// A wrong `oldPIN` costs one of the eight attempts that stand between the key and a
    /// permanent lock-out, so callers validate everything they can before calling.
    func changePIN(devicePath: String, oldPIN: String, newPIN: String) throws

    /// Erases every credential and PIN. Requires a touch within the key’s reset window.
    /// Sets a finite timeout and rejects a different expectedAAGUID within the same open;
    /// a matching AAGUID does not prove that the same physical key returned.
    func reset(devicePath: String, expectedAAGUID: String?, timeout: Duration) throws
}
