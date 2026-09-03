import Foundation

/// The strict reader behind `EncryptionKeyURL` and `SealedMessageURL`.
///
/// A link is a carrier (`LinkCarrier`) followed by a payload, and the payload is either
/// canonical or not ours: parameters in one fixed order, base64url without padding, nothing
/// extra. The carrier is matched without regard to case — schemes and hosts are
/// case-insensitive, and mail clients do write `Https://` — the payload byte for byte. The
/// only other leniency is whitespace — mail clients wrap long links — which is removed
/// before anything is looked at.
///
/// What it is careful about is the difference between *wrong* and *not finished*: someone
/// pasting or typing a link passes through many prefixes of a valid one, and every one of
/// those is reported as `.incomplete` rather than as a failure, so a field being typed into
/// does not shout at its user.
enum FidoPassLinkParser {
    /// Every host this build knows, so that a link of the other kind can be named as such.
    static let knownHosts = [EncryptionKeyURL.host, SealedMessageURL.host]
    private static let hexAlphabet = Set("0123456789abcdefABCDEF")

    struct Field {
        enum Encoding {
            case base64url
            /// Lower-case hex is written; either case is read.
            case hex
        }

        let name: String
        let encoding: Encoding
        let minimumByteCount: Int
        /// Nil for an unbounded field — a message's content.
        let maximumByteCount: Int?

        init(_ name: String, exactly count: Int) {
            self.name = name
            self.encoding = .base64url
            self.minimumByteCount = count
            self.maximumByteCount = count
        }

        init(_ name: String, atLeast count: Int) {
            self.name = name
            self.encoding = .base64url
            self.minimumByteCount = count
            self.maximumByteCount = nil
        }

        init(_ name: String, hexBytes count: Int) {
            self.name = name
            self.encoding = .hex
            self.minimumByteCount = count
            self.maximumByteCount = count
        }
    }

    struct Parsed {
        let values: [Data]
        /// Everything after the carrier, whitespace removed — what the canonical form is
        /// compared to.
        let payload: String
    }

    static func strip(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    static func parse(_ text: String, host expectedHost: String, fields: [Field]) throws -> Parsed {
        let stripped = strip(text)
        guard !stripped.isEmpty else { throw MessageCryptoError.incomplete }

        let payload = try payload(of: stripped)
        // The web carrier ends in `#`; a second one is not a link of ours, and cannot be a
        // prefix of one either.
        guard !payload.contains("#") else { throw MessageCryptoError.notFidoPassURL }

        let hostAndQuery = payload.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(hostAndQuery[0])
        guard hostAndQuery.count == 2 else {
            // No `?` yet: still typing the host, or a host we should name.
            if expectedHost.hasPrefix(host) { throw MessageCryptoError.incomplete }
            throw classify(host: host, expected: expectedHost)
        }
        if host != expectedHost { throw classify(host: host, expected: expectedHost) }

        let pairs = hostAndQuery[1].split(separator: "&", maxSplits: fields.count, omittingEmptySubsequences: false)
        guard pairs.count <= fields.count else { throw MessageCryptoError.notFidoPassURL }

        var values: [Data] = []
        for (index, field) in fields.enumerated() {
            guard index < pairs.count else { throw MessageCryptoError.incomplete }
            let pair = pairs[index]
            // The last pair present is the one that may still be growing.
            let mayBeUnfinished = index == pairs.count - 1

            let nameAndValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(nameAndValue[0])
            guard nameAndValue.count == 2 else {
                if mayBeUnfinished, field.name.hasPrefix(name) { throw MessageCryptoError.incomplete }
                throw MessageCryptoError.notFidoPassURL
            }
            guard name == field.name else { throw MessageCryptoError.notFidoPassURL }

            let encoded = String(nameAndValue[1])
            switch field.encoding {
            case .base64url:
                guard let bytes = Base64URL.decode(encoded) else {
                    // Either a character outside the alphabet, or a length no byte string
                    // has — which, while typing, is every fourth keystroke.
                    if mayBeUnfinished, encoded.unicodeScalars.allSatisfy(Base64URL.isAlphabet) {
                        throw MessageCryptoError.incomplete
                    }
                    throw MessageCryptoError.notFidoPassURL
                }
                if bytes.count < field.minimumByteCount {
                    if mayBeUnfinished { throw MessageCryptoError.incomplete }
                    throw MessageCryptoError.notFidoPassURL
                }
                if let maximum = field.maximumByteCount, bytes.count > maximum {
                    throw MessageCryptoError.notFidoPassURL
                }
                values.append(bytes)
            case .hex:
                guard encoded.allSatisfy({ hexAlphabet.contains($0) }) else { throw MessageCryptoError.notFidoPassURL }
                let length = field.minimumByteCount * 2
                if encoded.count < length {
                    if mayBeUnfinished { throw MessageCryptoError.incomplete }
                    throw MessageCryptoError.notFidoPassURL
                }
                guard encoded.count == length, let bytes = decodeHex(encoded) else {
                    throw MessageCryptoError.notFidoPassURL
                }
                values.append(bytes)
            }
        }

        return Parsed(values: values, payload: payload)
    }

    /// Removes the carrier. A prefix of a carrier is a link being typed; anything else is
    /// not ours.
    private static func payload(of stripped: String) throws -> String {
        for carrier in LinkCarrier.allCases {
            if hasPrefix(stripped, carrier.prefix) {
                return String(stripped.dropFirst(carrier.prefix.count))
            }
        }
        if LinkCarrier.allCases.contains(where: { hasPrefix($0.prefix, stripped) }) {
            throw MessageCryptoError.incomplete
        }
        throw MessageCryptoError.notFidoPassURL
    }

    /// Case-insensitive for ASCII letters only: a carrier is ASCII, and Unicode case
    /// folding (the Kelvin sign is a `k`) has no business in a link.
    private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        let textScalars = Array(text.unicodeScalars)
        let prefixScalars = Array(prefix.unicodeScalars)
        guard textScalars.count >= prefixScalars.count else { return false }
        return zip(textScalars, prefixScalars).allSatisfy { asciiLowercased($0) == asciiLowercased($1) }
    }

    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard ("A"..."Z").contains(scalar) else { return scalar }
        return Unicode.Scalar(scalar.value + 32) ?? scalar
    }

    private static func decodeHex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func classify(host: String, expected: String) -> MessageCryptoError {
        if knownHosts.contains(host) { return .unexpectedKind(host) }
        let versioned = host.range(of: "^hpke(blob)?v[0-9]+$", options: .regularExpression) != nil
        return versioned ? .unsupportedVersion(host) : .notFidoPassURL
    }
}
