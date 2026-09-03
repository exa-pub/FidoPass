import Foundation

/// Note: there is deliberately no "avoid ambiguous characters" switch.
///
/// The alphabet in `PasswordEngine` always excludes `i l o I L O 0 1`. Generated keys are
/// frequently transcribed by hand — onto a phone, into a disk-encryption prompt — where
/// telling `l` from `1` is guesswork. The flag existed but was never read, so removing it
/// changes no output; making it switchable would have been the wrong fix.
public struct PasswordPolicy: Codable, Hashable, Sendable {
    /// Lengths outside this range are clamped rather than rejected.
    ///
    /// The lower bound also protects `PasswordEngine.mapToPassword`, which divides by the
    /// number of produced characters while topping up missing character classes and would
    /// trap on an empty password.
    public static let lengthRange = 8...128

    public var length: Int
    public var useLower: Bool
    public var useUpper: Bool
    public var useDigits: Bool
    public var useSymbols: Bool
    public var version: Int

    public init(length: Int = 20,
                useLower: Bool = true,
                useUpper: Bool = true,
                useDigits: Bool = true,
                useSymbols: Bool = true,
                version: Int = 1) {
        self.length = Self.clampLength(length)
        self.useLower = useLower
        self.useUpper = useUpper
        self.useDigits = useDigits
        self.useSymbols = useSymbols
        self.version = version
    }

    /// Decoding goes through the same clamping as the memberwise initialiser. The
    /// synthesised conformance would bypass it and let an out-of-range length reach the
    /// engine.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.length = Self.clampLength(try container.decode(Int.self, forKey: .length))
        self.useLower = try container.decode(Bool.self, forKey: .useLower)
        self.useUpper = try container.decode(Bool.self, forKey: .useUpper)
        self.useDigits = try container.decode(Bool.self, forKey: .useDigits)
        self.useSymbols = try container.decode(Bool.self, forKey: .useSymbols)
        self.version = try container.decode(Int.self, forKey: .version)
    }

    private static func clampLength(_ value: Int) -> Int {
        min(max(value, lengthRange.lowerBound), lengthRange.upperBound)
    }
}
