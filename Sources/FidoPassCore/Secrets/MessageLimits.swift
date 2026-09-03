import Foundation

/// Limits the message windows need to know about without reaching into the sealer.
public enum MessageLimits {
    /// Longest text accepted for sealing.
    ///
    /// Both windows are ordinary text views; well before the crypto becomes a concern they
    /// stop being usable at all. A message this long is ~350 KB as a link.
    public static let maxPlaintextCharacters = 65_536
}
