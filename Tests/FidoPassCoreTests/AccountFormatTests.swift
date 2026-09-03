import XCTest
@testable import FidoPassCore

/// The relying parties are the format: they enter every credential and cannot be renamed.
final class AccountFormatTests: XCTestCase {

    /// Frozen: a web page has to be served under this domain to reach these credentials, and
    /// a credential cannot be moved to another.
    func testTheV2RelyingPartyIsFrozen() {
        XCTAssertEqual(AccountFormat.v2RelyingPartyId, "fidopass.org")
        XCTAssertEqual(AccountFormat.v2.rpId(for: .local), "fidopass.org")
        XCTAssertEqual(AccountFormat.v2.rpId(for: .portable), "fidopass.org", "one relying party for both kinds")
    }

    func testTheV1RelyingPartiesAreTheKinds() {
        XCTAssertEqual(AccountFormat.v1.rpId(for: .local), "fidopass.local")
        XCTAssertEqual(AccountFormat.v1.rpId(for: .portable), "fidopass.portable")
    }

    func testEveryRelyingPartyIsRead() {
        XCTAssertEqual(AccountFormat.relyingPartyIds, ["fidopass.local", "fidopass.portable", "fidopass.org"])
    }

    func testParsingNamesTheFormatAndForV1TheKind() {
        XCTAssertEqual(AccountFormat.parse(rpId: "fidopass.local")?.format, .v1)
        XCTAssertEqual(AccountFormat.parse(rpId: "fidopass.local")?.kind, .local)
        XCTAssertEqual(AccountFormat.parse(rpId: "fidopass.portable")?.format, .v1)
        XCTAssertEqual(AccountFormat.parse(rpId: "fidopass.portable")?.kind, .portable)
        XCTAssertEqual(AccountFormat.parse(rpId: "fidopass.org")?.format, .v2)
        XCTAssertNil(AccountFormat.parse(rpId: "fidopass.org")?.kind, "the kind of a v2 account is in its record")
        XCTAssertNil(AccountFormat.parse(rpId: "github.com"))
        XCTAssertNil(AccountFormat.parse(rpId: "www.fidopass.org"), "exact, not a suffix match")
    }

    func testAccountKindRoundTripsThroughRpId() {
        for kind in AccountKind.allCases {
            XCTAssertEqual(AccountKind(rpId: kind.rpId), kind)
        }
        XCTAssertNil(AccountKind(rpId: "example.com"))
        XCTAssertNil(AccountKind(rpId: AccountFormat.v2RelyingPartyId), "v2 is not a kind")
    }
}
