import XCTest
@testable import FidoPassCore

final class SaltFactoryTests: XCTestCase {
    func testResidentSaltDependsOnRevision() {
        let base = SaltFactory.residentSalt(label: "example",
                                            rpId: "fidopass.local",
                                            accountId: "acct",
                                            revision: 1)
        let updated = SaltFactory.residentSalt(label: "example",
                                               rpId: "fidopass.local",
                                               accountId: "acct",
                                               revision: 2)
        XCTAssertNotEqual(base, updated)
    }

    func testResidentSaltIsDeterministic() {
        let first = SaltFactory.residentSalt(label: "label",
                                             rpId: "rp",
                                             accountId: "acct",
                                             revision: 3)
        let second = SaltFactory.residentSalt(label: "label",
                                              rpId: "rp",
                                              accountId: "acct",
                                              revision: 3)
        XCTAssertEqual(first, second)
    }

    func testFixedComponentSaltIsStable() {
        let first = SaltFactory.fixedComponentSalt()
        let second = SaltFactory.fixedComponentSalt()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
    }

    func testPortableSaltNamespaceIsolation() {
        let base = SaltFactory.portableLabelSalt("example")
        let other = SaltFactory.residentSalt(label: "example",
                                             rpId: "fidopass.local",
                                             accountId: "acct",
                                             revision: 1)
        XCTAssertNotEqual(base, other)
    }
}
