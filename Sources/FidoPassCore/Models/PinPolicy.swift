import Foundation

/// The rules a key PIN has to satisfy, and the reasons it may not.
///
/// Not to be confused with `PasswordPolicy`, which shapes derived passwords. This one is
/// about the PIN of the authenticator itself, and it exists so the UI can refuse a bad PIN
/// in the field rather than after a round-trip.
///
/// The limits are libfido2's: `pad64` in `src/pin.c` rejects anything outside 4…63 **bytes**
/// with `FIDO_ERR_PIN_POLICY_VIOLATION`, before the value ever reaches the key. Checking the
/// same thing here changes no outcome, only when the user learns about it.
public struct PinPolicy: Equatable, Sendable {
    /// CTAP2's own floor, used when the key does not declare one of its own.
    public static let ctapFloor = 4
    /// libfido2 pads the PIN into a 64-byte buffer with a trailing NUL, so 63 is the ceiling.
    public static let maxLengthBytes = 63

    public var minLengthBytes: Int

    public init(minLengthBytes: Int = PinPolicy.ctapFloor) {
        // A key that declares a minimum below the CTAP floor is describing something the
        // protocol will not honour anyway.
        self.minLengthBytes = max(minLengthBytes, Self.ctapFloor)
    }

    public enum Issue: Equatable, Sendable {
        case empty
        case tooShort(min: Int)
        case tooLong(max: Int)
        /// A "change" that changes nothing. Some keys accept it silently, which is worse than
        /// refusing: the user believes the PIN was rotated when it was not.
        case sameAsOld
    }

    /// - Returns: the reason this PIN cannot be used, or `nil` when it can.
    public func validate(_ pin: String, oldPIN: String? = nil) -> Issue? {
        guard !pin.isEmpty else { return .empty }
        // Bytes, not characters. "пароль" is six characters and twelve bytes; an emoji PIN
        // hits the ceiling around the eighth symbol. Counting characters would let a PIN
        // through here that the key then rejects.
        let length = pin.utf8.count
        if length < minLengthBytes { return .tooShort(min: minLengthBytes) }
        if length > Self.maxLengthBytes { return .tooLong(max: Self.maxLengthBytes) }
        if let oldPIN, pin == oldPIN { return .sameAsOld }
        return nil
    }
}

extension PinPolicy.Issue {
    /// Wording aimed at the person typing, not at the log.
    public var message: String {
        switch self {
        case .empty:
            return "Enter a PIN."
        case .tooShort(let min):
            return "This key needs a PIN of at least \(min) characters."
        case .tooLong(let max):
            return "A PIN cannot be longer than \(max) bytes — accented letters and emoji count for several each."
        case .sameAsOld:
            return "The new PIN is the same as the current one."
        }
    }
}
