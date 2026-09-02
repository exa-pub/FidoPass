import XCTest
@testable import FidoPassCore

/// The manager window shows every credential on a key, including FidoPass's own — and a
/// portable account keeps its exported master key in the credential's `user.name`, which
/// credential management hands back for a PIN alone, with no touch.
///
/// Rendering that field verbatim would print a backup key on screen and write it into the
/// JSON export, bypassing `BackupKeyView` and its warning. These tests are what stops that
/// from coming back: the redaction happens in the core, before anything can encode it.
final class CredentialRedactionTests: XCTestCase {

    /// A real portable payload: 32 bytes, base64 — exactly what `EnrollmentService` writes.
    private let payload = Data(repeating: 0xA7, count: 32).base64EncodedString()

    func testPortableKeyMaterialIsWithheld() {
        let name = CredentialUserName.classify(rawName: payload, rpId: AccountKind.portable.rpId)
        XCTAssertEqual(name, .portableKeyMaterialWithheld(identity: nil))
        XCTAssertNil(name.revealed, "the material must not be reachable through the model")
        XCTAssertFalse(name.display.contains(payload), "the display string must not carry it either")
    }

    /// The current layout appends the account's identity to the material. The identity is
    /// not a secret and comes through; the 32 bytes in front of it still do not.
    func testCurrentLayoutWithholdsTheMaterialButKeepsTheIdentity() throws {
        let identity = try XCTUnwrap(AccountIdentity(hex: "0102030405060708090a0b0c"))
        let payload = try XCTUnwrap(PortablePayload(external: Data(repeating: 0xA7, count: 32), identity: identity))
        let name = CredentialUserName.classify(rawName: payload.base64, rpId: AccountKind.portable.rpId)
        XCTAssertEqual(name, .portableKeyMaterialWithheld(identity: identity))
        XCTAssertNil(name.revealed)
        XCTAssertFalse(name.display.contains(String(payload.base64.prefix(8))))

        let json = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
        XCTAssertTrue(json.contains(identity.hex), "the identity is what the export may show")
        XCTAssertFalse(json.contains(String(payload.base64.prefix(8))))
        XCTAssertFalse(json.contains(Data(repeating: 0xA7, count: 32).base64EncodedString().prefix(8)))
    }

    /// Redaction is keyed on the relying party, not on the shape of the string. A foreign
    /// service whose user name merely looks like base64 is not FidoPass key material, and
    /// hiding it would misrepresent what is on the key.
    func testForeignCredentialThatLooksLikeBase64IsNotRedacted() {
        let name = CredentialUserName.classify(rawName: payload, rpId: "github.com")
        XCTAssertEqual(name, .value(payload))
        XCTAssertEqual(name.revealed, payload)
    }

    /// A local FidoPass account stores its account id here, not key material.
    func testLocalFidoPassCredentialKeepsItsName() {
        let name = CredentialUserName.classify(rawName: "vault", rpId: AccountKind.local.rpId)
        XCTAssertEqual(name, .value("vault"))
    }

    /// A portable credential whose name is not a 32-byte payload is not key material — an
    /// account created by some other tool under the same relying party, say.
    func testPortableRelyingPartyWithNonPayloadNameIsNotRedacted() {
        let name = CredentialUserName.classify(rawName: "not-a-key", rpId: AccountKind.portable.rpId)
        XCTAssertEqual(name, .value("not-a-key"))
    }

    func testEmptyAndMissingNames() {
        XCTAssertEqual(CredentialUserName.classify(rawName: nil, rpId: "github.com"), CredentialUserName.none)
        XCTAssertEqual(CredentialUserName.classify(rawName: "", rpId: "github.com"), CredentialUserName.none)
    }

    /// The export is the reason redaction lives in the core rather than in a view: this is
    /// the encoder a view never touches.
    func testEncodedInventoryNeverContainsPortableKeyMaterial() throws {
        let credential = ResidentCredential(
            rpId: AccountKind.portable.rpId,
            credentialIdB64: Data(repeating: 0x11, count: 32).base64EncodedString(),
            userIdHex: "66",
            userIdUTF8: "f",
            userName: CredentialUserName.classify(rawName: payload, rpId: AccountKind.portable.rpId),
            userDisplayName: "f",
            coseAlgorithm: -7,
            publicKeyB64: Data(repeating: 0x22, count: 64).base64EncodedString(),
            credentialProtection: .uvOptional,
            hasLargeBlobKey: true)

        let inventory = CredentialInventory(
            relyingParties: [CredentialInventory.RelyingParty(id: AccountKind.portable.rpId,
                                                              name: nil,
                                                              idHashHex: "aa",
                                                              credentials: [credential])],
            residentKeysUsed: 1,
            residentKeysRemaining: 99,
            largeBlobArrayBytes: 1)

        let encoded = try JSONEncoder().encode(inventory)
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(json.contains(payload), "the export must not carry portable key material")
        // The payload's own prefix must not survive either: 32 bytes of base64 has no safe
        // truncation, so a "first 8 characters" style hint would still leak.
        XCTAssertFalse(json.contains(String(payload.prefix(8))))
        XCTAssertTrue(json.contains("portableKeyMaterialWithheld"), "but the fact of it should be visible")
    }

    /// `hasLargeBlobKey` is a flag precisely so the key itself cannot end up here.
    func testLargeBlobKeyIsOnlyEverAFlag() throws {
        let credential = ResidentCredential(rpId: "example.org",
                                            credentialIdB64: "AAAA",
                                            userIdHex: "01",
                                            userIdUTF8: nil,
                                            userName: .value("alice"),
                                            userDisplayName: nil,
                                            coseAlgorithm: -7,
                                            publicKeyB64: nil,
                                            credentialProtection: .uvRequired,
                                            hasLargeBlobKey: true)
        let json = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        XCTAssertTrue(json.contains("hasLargeBlobKey"))
        XCTAssertFalse(json.lowercased().contains("largeblobkeyb64"))
    }
}
