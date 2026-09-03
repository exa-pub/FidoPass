import XCTest
@testable import FidoPassCore

/// The key link is a frozen format: what this build writes has to be read, byte for byte,
/// by every build after it — and everything that is not exactly that has to be named for
/// what it is, without ever treating a half-pasted link as broken.
final class EncryptionKeyURLTests: XCTestCase {

    private func parse(_ text: String) -> Result<EncryptionKeyURL, MessageCryptoError> {
        do {
            return .success(try EncryptionKeyURL(parsing: text))
        } catch let error as MessageCryptoError {
            return .failure(error)
        } catch {
            XCTFail("unexpected error \(error)")
            return .failure(.notFidoPassURL)
        }
    }

    private func failure(_ text: String) -> MessageCryptoError? {
        if case .failure(let error) = parse(text) { return error }
        return nil
    }

    // MARK: - Shape

    func testShapeAndLength() throws {
        let url = try MessageFixtures.url()
        let text = url.absoluteString
        XCTAssertEqual(text.count, 164)
        XCTAssertTrue(text.hasPrefix("fidopass://keyv1?nonce="))
        XCTAssertTrue(text.contains("&pubkey="))
        XCTAssertTrue(text.contains("&idfp="))
        XCTAssertTrue(text.contains("#keyfp="))
        XCTAssertEqual(url.canonical + "#keyfp=" + url.fingerprint.hex, text)
        let query = String(text.split(separator: "?")[1])
        XCTAssertFalse(query.contains("+") || query.contains("/") || query.contains("=="), "URL alphabet, no padding")
    }

    func testRoundTrip() throws {
        let url = try MessageFixtures.url()
        XCTAssertEqual(try EncryptionKeyURL(parsing: url.absoluteString), url)
    }

    /// Mail clients wrap long links; the wrapped form has to read back.
    func testWhitespaceInsideIsIgnored() throws {
        let url = try MessageFixtures.url()
        let text = url.absoluteString
        var wrapped = ""
        for (index, character) in text.enumerated() {
            wrapped.append(character)
            if index % 40 == 39 { wrapped.append("\n  ") }
        }
        XCTAssertEqual(try EncryptionKeyURL(parsing: "  " + wrapped + " \n"), url)
    }

    func testFragmentHexIsCaseInsensitive() throws {
        let url = try MessageFixtures.url()
        let upper = url.canonical + "#keyfp=" + url.fingerprint.hex.uppercased()
        XCTAssertEqual(try EncryptionKeyURL(parsing: upper), url)
    }

    // MARK: - Incomplete is not wrong

    func testEveryPrefixIsIncomplete() throws {
        let url = try MessageFixtures.url()
        let text = url.absoluteString
        for length in 0..<text.count {
            let prefix = String(text.prefix(length))
            // The one prefix that is a whole link minus its fragment is exactly what a
            // channel that strips fragments delivers, and it is named as such.
            let expected: MessageCryptoError = length == url.canonical.count ? .checksumMissing : .incomplete
            XCTAssertEqual(failure(prefix), expected, "prefix of \(length) characters: \(prefix)")
        }
    }

    // MARK: - Wrong is named

    func testForeignLinkIsNotOurs() {
        XCTAssertEqual(failure("https://example.org/?nonce=abc"), .notFidoPassURL)
        XCTAssertEqual(failure("mailto:someone@example.org"), .notFidoPassURL)
        XCTAssertEqual(failure("fidopass://vault"), .notFidoPassURL)
    }

    func testAMessageIsNamedAsSuch() throws {
        let sealer = MessageSealer()
        let message = try sealer.seal("hi", for: try MessageFixtures.url())
        XCTAssertEqual(failure(message.absoluteString), .unexpectedKind("blobv1"))
    }

    func testANewerFormatIsNamedNotGuessed() throws {
        let text = try MessageFixtures.url().absoluteString.replacingOccurrences(of: "keyv1", with: "keyv2")
        XCTAssertEqual(failure(text), .unsupportedVersion("keyv2"))
    }

    func testMissingFragmentIsAMissingChecksum() throws {
        XCTAssertEqual(failure(try MessageFixtures.url().canonical), .checksumMissing)
    }

    func testDamagedLinkFailsItsChecksum() throws {
        let url = try MessageFixtures.url()
        let text = url.absoluteString
        // One character of the public key.
        let index = text.index(text.range(of: "&pubkey=")!.upperBound, offsetBy: 5)
        var damaged = text
        damaged.replaceSubrange(index...index, with: text[index] == "A" ? "B" : "A")
        XCTAssertEqual(failure(damaged), .checksumMismatch)

        // One digit of the fragment.
        let hexIndex = text.index(text.endIndex, offsetBy: -1)
        var wrongFragment = text
        wrongFragment.replaceSubrange(hexIndex...hexIndex, with: text[hexIndex] == "0" ? "1" : "0")
        XCTAssertEqual(failure(wrongFragment), .checksumMismatch)
    }

    func testNonCanonicalFormsAreRefused() throws {
        let url = try MessageFixtures.url()
        let nonce = Base64URL.encode(url.nonce)
        let pubkey = Base64URL.encode(url.publicKey)
        let idfp = Base64URL.encode(url.locator.bytes)
        let fragment = "#keyfp=" + url.fingerprint.hex

        XCTAssertEqual(failure("fidopass://keyv1?pubkey=\(pubkey)&nonce=\(nonce)&idfp=\(idfp)\(fragment)"),
                       .notFidoPassURL, "parameter order")
        XCTAssertEqual(failure("fidopass://keyv1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)&extra=1\(fragment)"),
                       .notFidoPassURL, "extra parameter")
        XCTAssertEqual(failure("FIDOPASS://KEYV1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)\(fragment)"),
                       .notFidoPassURL, "upper case")
        XCTAssertEqual(failure("fidopass://keyv1?nonce=\(nonce)=&pubkey=\(pubkey)&idfp=\(idfp)\(fragment)"),
                       .notFidoPassURL, "padding")
        XCTAssertEqual(failure("fidopass://keyv1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)#\(url.fingerprint.hex)"),
                       .notFidoPassURL, "fragment without its name")
        XCTAssertEqual(failure("fidopass://keyv1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)\(fragment)00"),
                       .notFidoPassURL, "fragment too long")
    }

    func testWrongFieldLengthsAreRefused() throws {
        let url = try MessageFixtures.url()
        let pubkey = Base64URL.encode(url.publicKey)
        let idfp = Base64URL.encode(url.locator.bytes)
        let shortNonce = Base64URL.encode(url.nonce.prefix(16))
        XCTAssertEqual(failure("fidopass://keyv1?nonce=\(shortNonce)&pubkey=\(pubkey)&idfp=\(idfp)#keyfp=000000000000"),
                       .notFidoPassURL)
        let longNonce = Base64URL.encode(url.nonce + url.nonce)
        XCTAssertEqual(failure("fidopass://keyv1?nonce=\(longNonce)&pubkey=\(pubkey)&idfp=\(idfp)#keyfp=000000000000"),
                       .notFidoPassURL)
    }

    func testZeroPublicKeyIsRefused() throws {
        let locator = try MessageFixtures.locator()
        XCTAssertThrowsError(try EncryptionKeyURL(nonce: MessageFixtures.nonce,
                                                  publicKey: Data(repeating: 0, count: 32),
                                                  locator: locator)) { error in
            XCTAssertEqual(error as? MessageCryptoError, .invalidPublicKey)
        }
        let nonce = Base64URL.encode(MessageFixtures.nonce)
        let zero = Base64URL.encode(Data(repeating: 0, count: 32))
        let idfp = Base64URL.encode(locator.bytes)
        XCTAssertEqual(failure("fidopass://keyv1?nonce=\(nonce)&pubkey=\(zero)&idfp=\(idfp)#keyfp=000000000000"),
                       .invalidPublicKey)
    }

    // MARK: - Fingerprint

    func testFingerprintIsOverTheCanonicalText() throws {
        let url = try MessageFixtures.url()
        XCTAssertEqual(url.fingerprint, try MessageKeyFingerprint.compute(canonical: url.canonical))
        XCTAssertNotEqual(url.fingerprint, try MessageFixtures.url(nonce: MessageFixtures.otherNonce).fingerprint)
    }
}
