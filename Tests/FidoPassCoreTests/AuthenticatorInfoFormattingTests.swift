import XCTest
@testable import FidoPassCore

/// The pure parts of turning what a key reports into something readable.
///
/// The rule they encode: a value this build does not recognise keeps its raw form rather
/// than collapsing to "unknown". A key advertising an algorithm or a verification method
/// nobody here has heard of is exactly the kind of thing this window exists to surface, and
/// mapping it to one word throws the information away.
final class AuthenticatorInfoFormattingTests: XCTestCase {

    func testKnownAlgorithmNames() {
        XCTAssertEqual(AuthenticatorInfo.algorithmName(cose: -7), "ES256")
        XCTAssertEqual(AuthenticatorInfo.algorithmName(cose: -8), "EdDSA")
        XCTAssertEqual(AuthenticatorInfo.algorithmName(cose: -35), "ES384")
        XCTAssertEqual(AuthenticatorInfo.algorithmName(cose: -257), "RS256")
    }

    func testUnknownAlgorithmKeepsItsNumber() {
        XCTAssertEqual(AuthenticatorInfo.algorithmName(cose: -1234), "alg -1234")
    }

    func testUVModalityBitmask() {
        XCTAssertEqual(AuthenticatorInfo.uvModalityNames(0), [])
        XCTAssertEqual(AuthenticatorInfo.uvModalityNames(0x0002), ["fingerprint"])
        XCTAssertEqual(AuthenticatorInfo.uvModalityNames(0x0004 | 0x0002), ["fingerprint", "pin"])
    }

    func testUnknownUVModalityBitsAreReportedRatherThanDropped() {
        // Bit 20 is not defined by any CTAP version this build knows.
        let names = AuthenticatorInfo.uvModalityNames(0x0004 | (1 << 20))
        XCTAssertTrue(names.contains("pin"))
        XCTAssertTrue(names.contains("bit 20"), "an unknown modality must still be visible")
    }

    func testFirmwareVersionUnpacksTheThreeBytes() {
        let info = Self.info(firmwareVersion: 0x050704)
        XCTAssertEqual(info.firmwareVersionString, "5.7.4")
    }

    /// `supportsCredentialManagement` is the difference between "this key holds nothing" and
    /// "this key cannot be asked", which the UI must never render the same way.
    func testCredentialManagementSupportIsReported() {
        XCTAssertFalse(Self.info(supportsCredMan: false).supportsCredentialManagement)
        XCTAssertTrue(Self.info(supportsCredMan: true).supportsCredentialManagement)
    }

    func testCredentialProtectionSummaries() {
        XCTAssertEqual(CredentialProtection(rawValue: 3), .uvRequired)
        XCTAssertNil(CredentialProtection(rawValue: 0), "0 is not a level — it is 'not reported'")
        XCTAssertNil(CredentialProtection(rawValue: 4))
        XCTAssertTrue(CredentialProtection.uvRequired.summary.contains("required"))
    }

    /// A `user.id` is opaque bytes. Authenticators accept ones that are not UTF-8 at all —
    /// verified on hardware — so the hex rendering is the only always-correct one.
    func testListLabelFallsBackThroughTheFieldsThatExist() {
        let withDisplay = Self.credential(display: "Alice Example", name: .value("alice"), utf8: "alice")
        XCTAssertEqual(withDisplay.listLabel, "Alice Example")

        let withName = Self.credential(display: nil, name: .value("alice"), utf8: "alice")
        XCTAssertEqual(withName.listLabel, "alice")

        let onlyUserId = Self.credential(display: nil, name: .none, utf8: "raw-id")
        XCTAssertEqual(onlyUserId.listLabel, "raw-id")

        // Nothing readable at all: the credential id is the only handle left, and a withheld
        // name must not become the label either.
        let opaque = Self.credential(display: nil, name: .portableKeyMaterialWithheld(identity: nil), utf8: nil)
        XCTAssertEqual(opaque.listLabel, String("Y3JlZC1pZC1iNjQ".prefix(12)))
    }

    /// A `user.id` of one control byte decodes as valid UTF-8 and draws as nothing, which
    /// would show an empty "user id (as text)" row where the honest answer is that the bytes
    /// are not text. Found on real hardware, on a credential whose id was `0x05`.
    func testUnreadableUserIdBytesAreNotOfferedAsText() {
        XCTAssertNil(ResidentCredential.readableText(from: Data([0x05])))
        XCTAssertNil(ResidentCredential.readableText(from: Data([0xff, 0xfe, 0x01, 0x02])), "not UTF-8 at all")
        XCTAssertNil(ResidentCredential.readableText(from: Data()))
        XCTAssertNil(ResidentCredential.readableText(from: Data([0x61, 0x00, 0x62])), "an embedded NUL is not readable")
        XCTAssertEqual(ResidentCredential.readableText(from: Data("vault".utf8)), "vault")
        XCTAssertEqual(ResidentCredential.readableText(from: Data("хранилище".utf8)), "хранилище")
        XCTAssertEqual(ResidentCredential.readableText(from: Data("a b".utf8)), "a b", "an ordinary space is readable")
    }

    func testFidoPassCredentialsAreRecognisedButNotByName() {
        XCTAssertTrue(Self.credential(rpId: AccountKind.local.rpId).isFidoPassCredential)
        XCTAssertTrue(Self.credential(rpId: AccountKind.portable.rpId).isFidoPassCredential)
        XCTAssertFalse(Self.credential(rpId: "github.com").isFidoPassCredential)
    }

    func testInventoryCountsSpanEveryRelyingParty() {
        let inventory = CredentialInventory(
            relyingParties: [
                CredentialInventory.RelyingParty(id: "a.test", name: nil, idHashHex: "00",
                                                 credentials: [Self.credential(rpId: "a.test")]),
                CredentialInventory.RelyingParty(id: "b.test", name: nil, idHashHex: "01",
                                                 credentials: [Self.credential(rpId: "b.test"),
                                                               Self.credential(rpId: "b.test", credentialId: "second")]),
            ],
            residentKeysUsed: 3,
            residentKeysRemaining: 97,
            largeBlobArrayBytes: nil)
        XCTAssertEqual(inventory.credentialCount, 3)
        XCTAssertEqual(inventory.allCredentials.count, 3)
    }

    // MARK: - Fixtures

    private static func credential(rpId: String = "example.org",
                                   credentialId: String = "Y3JlZC1pZC1iNjQ",
                                   display: String? = nil,
                                   name: CredentialUserName = .value("alice"),
                                   utf8: String? = nil) -> ResidentCredential {
        ResidentCredential(rpId: rpId,
                           credentialIdB64: credentialId,
                           userIdHex: "01",
                           userIdUTF8: utf8,
                           userName: name,
                           userDisplayName: display,
                           coseAlgorithm: -7,
                           publicKeyB64: nil,
                           credentialProtection: .uvOptional,
                           hasLargeBlobKey: false)
    }

    private static func info(firmwareVersion: UInt64 = 0,
                             supportsCredMan: Bool = true) -> AuthenticatorInfo {
        AuthenticatorInfo(isFIDO2: true,
                          ctapHIDProtocol: 2,
                          ctapHIDVersion: "5.7.4",
                          capabilities: ["wink", "cbor", "msg"],
                          supportsPIN: true,
                          supportsUV: false,
                          supportsCredentialManagement: supportsCredMan,
                          supportsCredentialProtection: true,
                          supportsPermissions: true,
                          hasPIN: true,
                          hasUV: false,
                          pinRetriesRemaining: 8,
                          uvRetriesRemaining: nil,
                          versions: ["FIDO_2_1"],
                          extensions: ["hmac-secret"],
                          options: [],
                          aaguid: nil,
                          pinProtocols: [2, 1],
                          algorithms: [],
                          transports: ["usb"],
                          certifications: [],
                          firmwareVersion: firmwareVersion,
                          limits: AuthenticatorInfo.Limits(maxMessageSize: 1536,
                                                           maxCredentialCountInList: 8,
                                                           maxCredentialIdLength: 128,
                                                           maxCredentialBlobLength: 32,
                                                           maxLargeBlob: 4096,
                                                           maxRPIDsForMinPINLength: 1),
                          minPINLength: 4,
                          forcePINChange: false,
                          remainingResidentKeys: 92,
                          uvAttempts: nil,
                          uvModalities: [])
    }
}
