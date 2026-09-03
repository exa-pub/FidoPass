import XCTest
@testable import FidoPassCore

/// The manager window shows every credential on a key, including FidoPass's own — and a
/// portable v1 account keeps its exported master key in the credential's `user.name`, which
/// credential management hands back for a PIN alone, with no touch.
///
/// Rendering that field verbatim would print a backup key on screen and write it into the
/// JSON export, bypassing `BackupKeyView` and its warning. These tests are what stops that
/// from coming back: the redaction happens in the core, before anything can encode it.
final class CredentialRedactionTests: XCTestCase {

    /// A real v1 portable payload: 32 bytes, base64 — exactly what released versions wrote.
    private let payload = Data(repeating: 0xA7, count: 32).base64EncodedString()

    func testPortableKeyMaterialIsWithheld() {
        let name = CredentialUserName.classify(rawName: payload, rpId: AccountKind.portable.rpId)
        XCTAssertEqual(name, .portableKeyMaterialWithheld)
        XCTAssertNil(name.revealed, "the material must not be reachable through the model")
        XCTAssertFalse(name.display.contains(payload), "the display string must not carry it either")
    }

    /// Redaction is keyed on the relying party, not on the shape of the string. A foreign
    /// service whose user name merely looks like base64 is not FidoPass key material, and
    /// hiding it would misrepresent what is on the key.
    func testForeignCredentialThatLooksLikeBase64IsNotRedacted() {
        let name = CredentialUserName.classify(rawName: payload, rpId: "github.com")
        XCTAssertEqual(name, .value(payload))
        XCTAssertEqual(name.revealed, payload)
    }

    /// A local v1 FidoPass account stores its account id here, not key material.
    func testLocalFidoPassCredentialKeepsItsName() {
        let name = CredentialUserName.classify(rawName: "vault", rpId: AccountKind.local.rpId)
        XCTAssertEqual(name, .value("vault"))
    }

    /// A v2 account's name is a name: nothing in it is withheld, whatever it looks like. The
    /// mask lives in the record, which the inventory never carries.
    func testV2NameIsNeverWithheld() {
        XCTAssertEqual(CredentialUserName.classify(rawName: "vault", rpId: AccountFormat.v2RelyingPartyId), .value("vault"))
        XCTAssertEqual(CredentialUserName.classify(rawName: payload, rpId: AccountFormat.v2RelyingPartyId), .value(payload))
    }

    /// A portable v1 credential whose name is not a 32-byte payload is not key material — an
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

    /// The manager shows an identity for FidoPass's own credentials — `user.id` for a v2
    /// one, derived for a local v1 one — and nothing for anyone else's, nor for a portable
    /// v1 one, which has none.
    func testResidentCredentialExposesTheIdentityAndOnlyThat() throws {
        let identity = try XCTUnwrap(AccountIdentity(hex: "0102030405060708090a0b0c0d0e0f10"))
        func credential(rpId: String, name: CredentialUserName, userIdHex: String = "66", record: ResidentCredential.RecordState? = nil) -> ResidentCredential {
            ResidentCredential(rpId: rpId,
                               credentialIdB64: Data("cred".utf8).base64EncodedString(),
                               userIdHex: userIdHex, userIdUTF8: nil,
                               userName: name, userDisplayName: "f",
                               coseAlgorithm: -7, publicKeyB64: nil,
                               credentialProtection: nil, hasLargeBlobKey: false,
                               record: record)
        }

        let local = credential(rpId: AccountKind.local.rpId, name: .value("vault"))
        XCTAssertEqual(local.accountIdentity, AccountIdentity.derived(fromCredentialId: Data("cred".utf8)))
        XCTAssertFalse(local.needsMigration)
        XCTAssertEqual(local.accountFormat, .v1)
        XCTAssertEqual(local.accountKind, .local)

        let legacy = credential(rpId: AccountKind.portable.rpId, name: .portableKeyMaterialWithheld)
        XCTAssertNil(legacy.accountIdentity)
        XCTAssertTrue(legacy.needsMigration)
        XCTAssertEqual(legacy.accountKind, .portable)

        let current = credential(rpId: AccountFormat.v2RelyingPartyId, name: .value("vault"), userIdHex: identity.hex, record: .portable)
        XCTAssertEqual(current.accountIdentity, identity)
        XCTAssertFalse(current.needsMigration)
        XCTAssertEqual(current.accountFormat, .v2)
        XCTAssertEqual(current.accountKind, .portable, "the kind of a v2 account comes from its record")

        let incomplete = credential(rpId: AccountFormat.v2RelyingPartyId, name: .value("vault"), userIdHex: identity.hex, record: .missing)
        XCTAssertNil(incomplete.accountKind, "without a record there is no kind to report")
        XCTAssertEqual(incomplete.accountIdentity, identity)

        let foreign = credential(rpId: "github.com", name: .value("alice"))
        XCTAssertNil(foreign.accountIdentity, "a foreign credential has no FidoPass identity, whatever its id hashes to")
        XCTAssertNil(foreign.accountFormat)
        XCTAssertFalse(foreign.needsMigration)
    }

    /// `hasLargeBlobKey` is a flag precisely so the key itself cannot end up here — and the
    /// record is a state, so the mask cannot either.
    func testLargeBlobKeyAndRecordAreOnlyEverStates() throws {
        let credential = ResidentCredential(rpId: AccountFormat.v2RelyingPartyId,
                                            credentialIdB64: "AAAA",
                                            userIdHex: "01",
                                            userIdUTF8: nil,
                                            userName: .value("alice"),
                                            userDisplayName: nil,
                                            coseAlgorithm: -7,
                                            publicKeyB64: nil,
                                            credentialProtection: .uvRequired,
                                            hasLargeBlobKey: true,
                                            record: .portable)
        let json = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        XCTAssertTrue(json.contains("hasLargeBlobKey"))
        XCTAssertFalse(json.lowercased().contains("largeblobkeyb64"))
        XCTAssertTrue(json.contains("\"record\":\"portable\""))
        XCTAssertFalse(json.lowercased().contains("mask"))
    }
}
