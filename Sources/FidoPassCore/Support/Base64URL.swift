import Foundation

/// Strict RFC 4648 §5 base64url without padding. Invalid alphabets, lengths and
/// noncanonical encodings are rejected.
enum Base64URL {
    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars)

    /// Whether a character could appear in an encoded value — what a field being typed
    /// into is checked against before its length makes sense.
    static func isAlphabet(_ scalar: Unicode.Scalar) -> Bool { alphabet.contains(scalar) }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard text.unicodeScalars.allSatisfy(alphabet.contains) else { return nil }
        // Every byte count encodes to a length of 0, 2 or 3 modulo 4; 1 is impossible.
        guard text.count % 4 != 1 else { return nil }
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        // Canonical only: trailing bits that are not zero decode to bytes that would encode
        // back to a different string, and that string is not what was written.
        guard let data = Data(base64Encoded: standard), encode(data) == text else { return nil }
        return data
    }
}
