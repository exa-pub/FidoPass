import Foundation

/// Operations that change the authenticator itself rather than what is stored on it.
///
/// Separate from `Enrolling` because the blast radius is different: enrolling
/// adds a credential, these three change or destroy the key's own state. Behind a protocol
/// so the app layer can be tested on a machine with no authenticator — and so no test ever
/// needs real hardware to reach this code, which is the code that could brick a key.
public protocol DeviceManaging: Sendable {
    /// Sets the very first PIN. The key refuses with `.notAllowed` if it already has one.
    func setInitialPIN(devicePath: String, newPIN: String) throws

    /// Replaces the PIN, proving knowledge of the old one.
    ///
    /// A wrong `oldPIN` costs one of the eight attempts that stand between the key and a
    /// permanent lock-out, so callers validate everything they can before calling.
    func changePIN(devicePath: String, oldPIN: String, newPIN: String) throws

    /// Erases every credential and the PIN.
    ///
    /// Needs a touch, and most keys only accept it within a few seconds of being plugged in.
    /// `timeout` is passed to the device so the call cannot block forever — libfido2 defaults
    /// to waiting indefinitely, and this operation is the one where that matters.
    ///
    /// `expectedAAGUID`, when given, is checked inside the same open as the reset itself: the
    /// reset flow makes the user unplug the key, and a device path does not survive that, so
    /// something has to notice if a *different* key came back. It is a one-way check — a
    /// matching AAGUID proves nothing, a differing one proves the key is not the same — and it
    /// costs no extra open, which matters when the window to issue a reset is seconds wide.
    func reset(devicePath: String, expectedAAGUID: String?, timeout: Duration) throws
}
