import Foundation

/// Limits the message windows need to know about without reaching into the sealer.
public enum MessageLimits {
    /// Longest text accepted for sealing.
    ///
    /// Both windows are ordinary text views; well before the crypto becomes a concern they
    /// stop being usable at all. A message this long is ~350 KB as a link.
    public static let maxPlaintextCharacters = 65_536
    /// Resource bounds, independent of the frozen message format. A grapheme may contain
    /// arbitrarily many combining scalars, so character count alone cannot bound memory.
    public static let maxPlaintextBytes = 1_048_576
    public static let maxLinkBytes = 1_500_000
    public static let maxKeyLinkBytes = 4_096
}
