import XCTest
@testable import FidoPassCore

/// The key link is a frozen format: what this build writes has to be read, byte for byte,
/// by every build after it — in either carrier — and everything that is not exactly that
/// has to be named for what it is, without ever treating a half-pasted link as broken.
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
        let web = url.absoluteString(carrier: .web)
        XCTAssertEqual(web.count, 180)
        XCTAssertTrue(web.hasPrefix("https://fidopass.org/link#hpkev1?nonce="))
        XCTAssertTrue(web.contains("&pubkey="))
        XCTAssertTrue(web.contains("&idfp="))
        XCTAssertTrue(web.contains("&keyfp="))
        XCTAssertEqual("https://fidopass.org/link#" + url.payload + "&keyfp=" + url.fingerprint.hex, web)

        let app = url.absoluteString(carrier: .app)
        XCTAssertEqual(app.count, 165)
        XCTAssertTrue(app.hasPrefix("fidopass://hpkev1?nonce="))
        XCTAssertEqual("fidopass://" + url.payload + "&keyfp=" + url.fingerprint.hex, app)

        XCTAssertTrue(url.payload.hasPrefix("hpkev1?nonce="), "the payload carries no carrier")
        XCTAssertFalse(url.payload.contains("keyfp"), "and no checksum")
        let query = String(web.split(separator: "?")[1])
        XCTAssertFalse(query.contains("+") || query.contains("/") || query.contains("=="), "URL alphabet, no padding")
    }

    /// What the app writes is the web carrier — the one that is clickable everywhere.
    func testTheAppWritesTheWebCarrier() throws {
        let url = try MessageFixtures.url()
        XCTAssertEqual(LinkCarrier.written, .web)
        XCTAssertEqual(url.absoluteString, url.absoluteString(carrier: .web))
    }

    func testBothCarriersReadTheSameKey() throws {
        let url = try MessageFixtures.url()
        for carrier in LinkCarrier.allCases {
            XCTAssertEqual(try EncryptionKeyURL(parsing: url.absoluteString(carrier: carrier)), url, "\(carrier)")
        }
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

    /// Schemes and hosts are case-insensitive, and some clients capitalise them; the payload
    /// is not, and is refused in any other case.
    func testCarrierIsCaseInsensitiveAndThePayloadIsNot() throws {
        let url = try MessageFixtures.url()
        let tail = url.payload + "&keyfp=" + url.fingerprint.hex
        XCTAssertEqual(try EncryptionKeyURL(parsing: "Https://FidoPass.org/link#" + tail), url)
        XCTAssertEqual(try EncryptionKeyURL(parsing: "FIDOPASS://" + tail), url)
        XCTAssertEqual(failure("https://fidopass.org/link#" + tail.uppercased()), .notFidoPassURL)
        XCTAssertEqual(failure("https://fidopass.org/LINK#" + tail), .notFidoPassURL, "the path is part of the carrier as written")
    }

    func testChecksumHexIsCaseInsensitive() throws {
        let url = try MessageFixtures.url()
        let upper = "https://fidopass.org/link#" + url.payload + "&keyfp=" + url.fingerprint.hex.uppercased()
        XCTAssertEqual(try EncryptionKeyURL(parsing: upper), url)
    }

    // MARK: - Incomplete is not wrong

    /// Every prefix of a valid link, in either carrier, is a link being typed — the one that
    /// stops just before `&keyfp=` included: the checksum is required, but its absence looks
    /// exactly like an unfinished paste.
    func testEveryPrefixIsIncomplete() throws {
        let url = try MessageFixtures.url()
        for carrier in LinkCarrier.allCases {
            let text = url.absoluteString(carrier: carrier)
            for length in 0..<text.count {
                let prefix = String(text.prefix(length))
                XCTAssertEqual(failure(prefix), .incomplete, "prefix of \(length) characters: \(prefix)")
            }
        }
    }

    // MARK: - Wrong is named

    func testForeignLinkIsNotOurs() {
        XCTAssertEqual(failure("https://example.org/?nonce=abc"), .notFidoPassURL)
        XCTAssertEqual(failure("mailto:someone@example.org"), .notFidoPassURL)
        XCTAssertEqual(failure("fidopass://vault"), .notFidoPassURL)
        XCTAssertEqual(failure("https://fidopass.org/other#hpkev1?nonce=abc"), .notFidoPassURL)
    }

    /// The carrier is exactly one string: no plain http, no other host, and the payload in
    /// the fragment — a query would reach the server.
    func testOtherCarriersAreNotOurs() throws {
        let tail = try MessageFixtures.url().payload + "&keyfp=" + MessageFixtures.url().fingerprint.hex
        XCTAssertEqual(failure("http://fidopass.org/link#" + tail), .notFidoPassURL)
        XCTAssertEqual(failure("https://www.fidopass.org/link#" + tail), .notFidoPassURL)
        XCTAssertEqual(failure("https://fidopass.org/link?" + tail), .notFidoPassURL)
        XCTAssertEqual(failure("https://fidopass.org/link/#" + tail), .notFidoPassURL)
    }

    /// The hosts of the unreleased format are not ours — not older, not newer, just not.
    func testTheOldHostsAreNotOurs() throws {
        let url = try MessageFixtures.url()
        let old = "fidopass://keyv1?nonce=\(Base64URL.encode(url.nonce))&pubkey=\(Base64URL.encode(url.publicKey))&idfp=\(Base64URL.encode(url.locator.bytes))#keyfp=\(url.fingerprint.hex)"
        XCTAssertEqual(failure(old), .notFidoPassURL)
    }

    func testAMessageIsNamedAsSuch() throws {
        let sealer = MessageSealer()
        let message = try sealer.seal("hi", for: try MessageFixtures.url())
        for carrier in LinkCarrier.allCases {
            XCTAssertEqual(failure(message.absoluteString(carrier: carrier)), .unexpectedKind("hpkeblobv1"))
        }
    }

    func testANewerFormatIsNamedNotGuessed() throws {
        let text = try MessageFixtures.url().absoluteString.replacingOccurrences(of: "hpkev1", with: "hpkev2")
        XCTAssertEqual(failure(text), .unsupportedVersion("hpkev2"))
    }

    func testDamagedLinkFailsItsChecksum() throws {
        let url = try MessageFixtures.url()
        let text = url.absoluteString
        // One character of the public key.
        let index = text.index(text.range(of: "&pubkey=")!.upperBound, offsetBy: 5)
        var damaged = text
        damaged.replaceSubrange(index...index, with: text[index] == "A" ? "B" : "A")
        XCTAssertEqual(failure(damaged), .checksumMismatch)

        // One digit of the checksum.
        let hexIndex = text.index(text.endIndex, offsetBy: -1)
        var wrongChecksum = text
        wrongChecksum.replaceSubrange(hexIndex...hexIndex, with: text[hexIndex] == "0" ? "1" : "0")
        XCTAssertEqual(failure(wrongChecksum), .checksumMismatch)
    }

    func testNonCanonicalFormsAreRefused() throws {
        let url = try MessageFixtures.url()
        let nonce = Base64URL.encode(url.nonce)
        let pubkey = Base64URL.encode(url.publicKey)
        let idfp = Base64URL.encode(url.locator.bytes)
        let keyfp = url.fingerprint.hex
        let carrier = "https://fidopass.org/link#"

        XCTAssertEqual(failure("\(carrier)hpkev1?pubkey=\(pubkey)&nonce=\(nonce)&idfp=\(idfp)&keyfp=\(keyfp)"),
                       .notFidoPassURL, "parameter order")
        XCTAssertEqual(failure("\(carrier)hpkev1?nonce=\(nonce)&pubkey=\(pubkey)&keyfp=\(keyfp)&idfp=\(idfp)"),
                       .notFidoPassURL, "checksum before the locator")
        XCTAssertEqual(failure("\(carrier)hpkev1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)&extra=1&keyfp=\(keyfp)"),
                       .notFidoPassURL, "extra parameter")
        XCTAssertEqual(failure("\(carrier)hpkev1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)&keyfp=\(keyfp)&x=1"),
                       .notFidoPassURL, "trailing parameter")
        XCTAssertEqual(failure("\(carrier)HPKEV1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)&keyfp=\(keyfp)"),
                       .notFidoPassURL, "upper case host")
        XCTAssertEqual(failure("\(carrier)hpkev1?nonce=\(nonce)=&pubkey=\(pubkey)&idfp=\(idfp)&keyfp=\(keyfp)"),
                       .notFidoPassURL, "padding")
        XCTAssertEqual(failure("\(carrier)hpkev1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)#keyfp=\(keyfp)"),
                       .notFidoPassURL, "checksum as a fragment")
        XCTAssertEqual(failure("\(carrier)hpkev1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)&keyfp=\(keyfp)00"),
                       .notFidoPassURL, "checksum too long")
        XCTAssertEqual(failure("\(carrier)hpkev1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)&keyfp=\(keyfp.dropLast(2))zz"),
                       .notFidoPassURL, "checksum not hex")
        XCTAssertEqual(failure("\(carrier)hpkev1?nonce=\(nonce)&pubkey=\(pubkey)&idfp=\(idfp)&keyfp=\(keyfp)#"),
                       .notFidoPassURL, "a second fragment")
    }

    func testWrongFieldLengthsAreRefused() throws {
        let url = try MessageFixtures.url()
        let pubkey = Base64URL.encode(url.publicKey)
        let idfp = Base64URL.encode(url.locator.bytes)
        let shortNonce = Base64URL.encode(url.nonce.prefix(16))
        XCTAssertEqual(failure("fidopass://hpkev1?nonce=\(shortNonce)&pubkey=\(pubkey)&idfp=\(idfp)&keyfp=000000000000"),
                       .notFidoPassURL)
        let longNonce = Base64URL.encode(url.nonce + url.nonce)
        XCTAssertEqual(failure("fidopass://hpkev1?nonce=\(longNonce)&pubkey=\(pubkey)&idfp=\(idfp)&keyfp=000000000000"),
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
        XCTAssertEqual(failure("fidopass://hpkev1?nonce=\(nonce)&pubkey=\(zero)&idfp=\(idfp)&keyfp=000000000000"),
                       .invalidPublicKey)
    }

    // MARK: - Fingerprint

    /// Over the payload, not the link: the same key spells the same emoji in either carrier.
    func testFingerprintIsOverThePayload() throws {
        let url = try MessageFixtures.url()
        XCTAssertEqual(url.fingerprint, try MessageKeyFingerprint.compute(payload: url.payload))
        XCTAssertNotEqual(url.fingerprint, try MessageFixtures.url(nonce: MessageFixtures.otherNonce).fingerprint)
        let fromWeb = try EncryptionKeyURL(parsing: url.absoluteString(carrier: .web))
        let fromApp = try EncryptionKeyURL(parsing: url.absoluteString(carrier: .app))
        XCTAssertEqual(fromWeb.fingerprint, fromApp.fingerprint)
    }
}
