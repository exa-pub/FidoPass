import Sparkle
import XCTest

/// The version scheme from scripts/version.sh, checked against the comparator Sparkle
/// actually uses to decide whether an appcast item is newer than the running app.
final class VersionComparatorTests: XCTestCase {

    private func assertOrdered(_ older: String, _ newer: String, file: StaticString = #filePath, line: UInt = #line) {
        let comparator = SUStandardVersionComparator.default
        XCTAssertEqual(comparator.compareVersion(older, toVersion: newer), .orderedAscending,
                       "\(older) must sort before \(newer)", file: file, line: line)
        XCTAssertEqual(comparator.compareVersion(newer, toVersion: older), .orderedDescending,
                       "\(newer) must sort after \(older)", file: file, line: line)
    }

    func testReleasesAreMonotonic() {
        assertOrdered("0.9.0", "0.17.0")
        assertOrdered("0.17.0", "0.18.0")
        assertOrdered("0.18.0", "0.18.1")
        assertOrdered("0.99.9", "1.0.0")
        XCTAssertEqual(SUStandardVersionComparator.default.compareVersion("0.17.0", toVersion: "0.17.0"), .orderedSame)
    }

    /// A build after a tag sits between that release and the next one in either direction.
    func testDevelopmentBuildsSitBetweenReleases() {
        assertOrdered("0.17.0", "0.17.0.8")
        assertOrdered("0.17.0.8", "0.17.1")
        assertOrdered("0.17.0.8", "0.18.0")
        assertOrdered("0.17.0.8", "0.17.0.9")
    }

    /// Why version.sh does not write a prerelease's CFBundleVersion as the tag says: Sparkle
    /// ignores everything after a dash, so the beta and the release would be the same version.
    func testSemverSuffixesAreInvisibleToSparkle() {
        let comparator = SUStandardVersionComparator.default
        XCTAssertEqual(comparator.compareVersion("0.18.0-beta.1", toVersion: "0.18.0"), .orderedSame)
        XCTAssertEqual(comparator.compareVersion("0.18.0-beta.1", toVersion: "0.18.0-beta.2"), .orderedSame)
    }

    /// The notation it does order, which is what a prerelease tag is written as.
    func testPrereleasesPrecedeTheirRelease() {
        assertOrdered("0.18.0a1", "0.18.0b1")
        assertOrdered("0.18.0b1", "0.18.0b2")
        assertOrdered("0.18.0b9", "0.18.0b10")
        assertOrdered("0.18.0b2", "0.18.0rc1")
        assertOrdered("0.18.0rc1", "0.18.0")
        assertOrdered("0.17.0", "0.18.0b1")
        assertOrdered("0.17.0.8", "0.18.0b1")
        assertOrdered("0.18.0b1.3", "0.18.0")
    }
}
