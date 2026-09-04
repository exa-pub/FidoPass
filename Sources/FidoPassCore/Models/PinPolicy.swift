import Foundation

/// New PINs use a Unicode scalar minimum and UTF-8 byte maximum. Existing PINs retain
/// their exact bytes: never normalize or retry alternate encodings against a key.
public struct PinPolicy: Equatable, Sendable {
    /// CTAP2's own floor, used when the key does not declare one of its own.
    public static let ctapFloor = 4
    /// libfido2 pads the PIN into a 64-byte buffer with a trailing NUL, so 63 is the ceiling.
    public static let maxLengthBytes = 63

    public var minimumCodePoints: Int

    public init(minimumCodePoints: Int = PinPolicy.ctapFloor) {
        // A key that declares a minimum below the CTAP floor is describing something the
        // protocol will not honour anyway.
        self.minimumCodePoints = max(minimumCodePoints, Self.ctapFloor)
    }

    public enum Issue: Equatable, Sendable {
        case empty
        case containsNUL
        case notNormalized
        case tooShort(min: Int)
        case tooLong(max: Int)
        /// A "change" that changes nothing. Some keys accept it silently, which is worse than
        /// refusing: the user believes the PIN was rotated when it was not.
        case sameAsOld
    }

    /// - Returns: the reason this PIN cannot be used, or `nil` when it can.
    public func validate(_ pin: String, oldPIN: String? = nil) -> Issue? {
        guard !pin.isEmpty else { return .empty }
        if pin.utf8.contains(0) { return .containsNUL }
        if pin.unicodeScalars.count < minimumCodePoints { return .tooShort(min: minimumCodePoints) }
        if pin.utf8.count > Self.maxLengthBytes { return .tooLong(max: Self.maxLengthBytes) }
        if !pin.utf8.elementsEqual(pin.precomposedStringWithCanonicalMapping.utf8) { return .notNormalized }
        if let oldPIN, pin.utf8.elementsEqual(oldPIN.utf8) { return .sameAsOld }
        return nil
    }
    /// Accept the historical byte floor when unlocking. A raised minimum governs the new
    /// PIN only; rejecting an older PIN here could make the required change impossible.
    public static func validateExisting(_ pin: String) -> Issue? {
        if pin.isEmpty { return .empty }
        if pin.utf8.contains(0) { return .containsNUL }
        if pin.utf8.count < ctapFloor { return .tooShort(min: ctapFloor) }
        if pin.utf8.count > maxLengthBytes { return .tooLong(max: maxLengthBytes) }
        return nil
    }

}

extension PinPolicy.Issue {
    /// Wording aimed at the person typing, not at the log.
    public var message: String {
        switch self {
        case .empty:
            return "Enter a PIN."
        case .containsNUL:
            return "A PIN cannot contain a NUL character."
        case .notNormalized:
            return "Use precomposed characters for the new PIN (Unicode NFC)."
        case .tooShort(let min):
            return "This key needs a PIN of at least \(min) characters."
        case .tooLong(let max):
            return "A PIN cannot be longer than \(max) bytes — accented letters and emoji count for several each."
        case .sameAsOld:
            return "The new PIN is the same as the current one."
        }
    }
}
