import Foundation

/// The authenticator's own settings — CTAP 2.1 `authenticatorConfig`.
///
/// Separate from `DeviceManaging`, which is PIN and reset. These change how the key behaves
/// from now on rather than what it holds, and two of them cannot be undone, so they are
/// grouped where that can be said once and enforced by the type.
///
/// Every one of them needs the PIN. None of them needs a touch — verified on hardware.
public protocol DeviceConfiguring: Sendable {
    /// Flips `alwaysUv`: whether the key insists on user verification for *every* operation,
    /// including ones a relying party asked to be allowed without it.
    ///
    /// A toggle, so it is reversible — the one setting here that is. Reads back the resulting
    /// state rather than assuming it: the request carries no value, only "flip it".
    @discardableResult
    func toggleAlwaysUV(devicePath: String, pin: String) throws -> Bool

    /// Raises the shortest PIN the key will accept.
    ///
    /// **Cannot be undone and cannot be lowered.** The key rejects any value that is not
    /// greater than the current minimum. If the new minimum exceeds the length of the PIN in
    /// use, the key also demands that the PIN be changed before it will do anything else.
    func setMinimumPINLength(devicePath: String, length: Int, pin: String) throws

    /// Makes the key demand a new PIN before its next operation.
    ///
    /// Undone only by actually changing the PIN. Nothing else on the key works until then.
    func forcePINChange(devicePath: String, pin: String) throws

    /// Turns on enterprise attestation, which lets the key identify itself individually to
    /// relying parties that ask for it.
    ///
    /// **Cannot be undone.** Only offered by keys that advertise the `ep` option, which most
    /// consumer keys do not.
    func enableEnterpriseAttestation(devicePath: String, pin: String) throws
}
