import Foundation

/// The strict reader behind `EncryptionKeyURL` and `SealedMessageURL`.
///
/// A link is either canonical or not ours: parameters in one fixed order, base64url without
/// padding, nothing extra. The only leniency is whitespace — mail clients wrap long links —
/// which is removed before anything is looked at.
///
/// What it is careful about is the difference between *wrong* and *not finished*: someone
/// pasting or typing a link passes through many prefixes of a valid one, and every one of
/// those is reported as `.incomplete` rather than as a failure, so a field being typed into
/// does not shout at its user.
enum FidoPassLinkParser {
    static let scheme = "fidopass://"
    /// Every host this build knows, so that a link of the other kind can be named as such.
    static let knownHosts = [EncryptionKeyURL.host, SealedMessageURL.host]

    struct Field {
        let name: String
        let minimumByteCount: Int
        /// Nil for an unbounded field — a message's content.
        let maximumByteCount: Int?

        init(_ name: String, exactly count: Int) {
            self.name = name
            self.minimumByteCount = count
            self.maximumByteCount = count
        }

        init(_ name: String, atLeast count: Int) {
            self.name = name
            self.minimumByteCount = count
            self.maximumByteCount = nil
        }
    }

    struct Parsed {
        let values: [Data]
        /// Whatever followed `#`, if anything.
        let fragment: String?
        /// The text before `#`, whitespace removed — what the canonical form is compared to.
        let body: String
    }

    static func strip(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    static func parse(_ text: String, host expectedHost: String, fields: [Field]) throws -> Parsed {
        let stripped = strip(text)
        guard !stripped.isEmpty else { throw MessageCryptoError.incomplete }

        guard stripped.lowercased().hasPrefix(scheme) else {
            if scheme.hasPrefix(stripped.lowercased()) { throw MessageCryptoError.incomplete }
            throw MessageCryptoError.notFidoPassURL
        }

        let halves = stripped.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let body = String(halves[0])
        let fragment = halves.count > 1 ? String(halves[1]) : nil

        let afterScheme = body.dropFirst(scheme.count)
        let hostAndQuery = afterScheme.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
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
            // The last pair of a link with no fragment is the one that may still be growing.
            let mayBeUnfinished = index == pairs.count - 1 && fragment == nil

            let nameAndValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(nameAndValue[0])
            guard nameAndValue.count == 2 else {
                if mayBeUnfinished, field.name.hasPrefix(name) { throw MessageCryptoError.incomplete }
                throw MessageCryptoError.notFidoPassURL
            }
            guard name == field.name else { throw MessageCryptoError.notFidoPassURL }

            let encoded = String(nameAndValue[1])
            guard let bytes = Base64URL.decode(encoded) else {
                // Either a character outside the alphabet, or a length no byte string has —
                // which, while typing, is every fourth keystroke.
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
        }

        return Parsed(values: values, fragment: fragment, body: body)
    }

    private static func classify(host: String, expected: String) -> MessageCryptoError {
        if knownHosts.contains(host) { return .unexpectedKind(host) }
        let versioned = host.range(of: "^(key|blob)v[0-9]+$", options: .regularExpression) != nil
        return versioned ? .unsupportedVersion(host) : .notFidoPassURL
    }
}
