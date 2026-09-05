import XCTest
import FidoPassAppKit
@testable import FidoPassUpdater

/// The state machine that stands in for Sparkle's windows.
@MainActor
final class UpdateFlowTests: XCTestCase {

    private let release = UpdateCandidate(version: "0.19.0", build: "0.19.0",
                                          releaseNotesURL: URL(string: "https://github.com/exa-pub/FidoPass/releases/tag/v0.19.0"))
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeFlow() -> (UpdateFlow, () -> [UpdateState]) {
        let flow = UpdateFlow()
        flow.now = { [fixedNow] in fixedNow }
        var seen: [UpdateState] = []
        flow.onChange = { seen.append($0) }
        return (flow, { seen })
    }

    /// A scheduled check that finds something is dismissed at once — the session must end so
    /// tomorrow's check still runs — and what it found stays offered.
    func testScheduledFindIsOfferedAndDismissed() {
        let (flow, seen) = makeFlow()
        XCTAssertEqual(flow.found(release, stage: .notDownloaded), .dismiss)
        XCTAssertEqual(flow.state, .available(release))
        XCTAssertTrue(flow.state.offersInstall)
        flow.sessionEnded()
        XCTAssertEqual(flow.state, .available(release), "ending the session must not take the dot away")
        XCTAssertEqual(seen(), [.available(release)])
    }

    /// The click: a second check, answered "install" this time, then progress to relaunch.
    func testClickInstallsThroughTheNextCheck() {
        let (flow, _) = makeFlow()
        _ = flow.found(release, stage: .notDownloaded)

        XCTAssertTrue(flow.requestInstall())
        XCTAssertEqual(flow.state, .downloading(release, fraction: nil))
        flow.checkStarted()
        XCTAssertEqual(flow.state, .downloading(release, fraction: nil), "no flash of 'checking' over an install")
        XCTAssertEqual(flow.found(release, stage: .notDownloaded), .install)

        flow.downloadStarted()
        XCTAssertEqual(flow.state, .downloading(release, fraction: 0))
        flow.downloadExpects(200)
        flow.downloadReceived(50)
        XCTAssertEqual(flow.state, .downloading(release, fraction: 0.25))
        flow.downloadReceived(150)
        XCTAssertEqual(flow.state, .downloading(release, fraction: 1))
        flow.extracting()
        XCTAssertEqual(flow.state, .installing(release))
        XCTAssertEqual(flow.readyToInstall(), .install)
        flow.installing()
        XCTAssertEqual(flow.state, .installing(release))
        XCTAssertFalse(flow.installRequested)
        XCTAssertTrue(flow.state.isInstalling)
        XCTAssertFalse(flow.state.offersInstall)
    }

    /// Without a known size the row says "preparing", not a made-up percentage.
    func testUnknownSizeHasNoFraction() {
        let (flow, _) = makeFlow()
        _ = flow.found(release, stage: .notDownloaded)
        _ = flow.requestInstall()
        flow.downloadStarted()
        flow.downloadReceived(1024)
        XCTAssertEqual(flow.state, .downloading(release, fraction: nil))
    }

    /// Background downloads: Sparkle reports the update already downloaded. The dot means
    /// "verified, click to relaunch"; the click goes straight to installing.
    func testDownloadedUpdateIsReadyAndClickInstalls() {
        let (flow, _) = makeFlow()
        XCTAssertEqual(flow.found(release, stage: .downloaded), .dismiss)
        XCTAssertEqual(flow.state, .readyToInstall(release))
        XCTAssertTrue(flow.requestInstall())
        XCTAssertEqual(flow.found(release, stage: .downloaded), .install)
        XCTAssertEqual(flow.state, .installing(release))
    }

    func testNothingToInstallWhenNothingIsOffered() {
        let (flow, seen) = makeFlow()
        XCTAssertFalse(flow.requestInstall())
        flow.checkStarted()
        flow.notFound()
        XCTAssertEqual(flow.state, .upToDate(checkedAt: fixedNow))
        XCTAssertFalse(flow.requestInstall())
        flow.failed("Offline")
        XCTAssertFalse(flow.requestInstall())
        XCTAssertEqual(seen(), [.checking, .upToDate(checkedAt: fixedNow), .failed(message: "Offline", at: fixedNow)])
    }

    /// The release the dot pointed at was pulled between the find and the click.
    func testClickOnAVanishedReleaseFails() {
        let (flow, _) = makeFlow()
        _ = flow.found(release, stage: .notDownloaded)
        _ = flow.requestInstall()
        flow.checkStarted()
        flow.notFound()
        guard case .failed(let message, let at) = flow.state else { return XCTFail("expected failure, got \(flow.state)") }
        XCTAssertEqual(at, fixedNow)
        XCTAssertTrue(message.contains("no longer available"))
        XCTAssertFalse(flow.installRequested)
        XCTAssertNil(flow.state.menuTitle, "a failure is a sentence in Preferences, not a menu item")
    }

    /// An error mid-download clears the request; the next find is offered again, not installed.
    func testErrorDuringInstallClearsTheRequest() {
        let (flow, _) = makeFlow()
        _ = flow.found(release, stage: .notDownloaded)
        _ = flow.requestInstall()
        flow.downloadStarted()
        flow.failed("The update could not be downloaded.")
        XCTAssertFalse(flow.installRequested)
        XCTAssertEqual(flow.found(release, stage: .notDownloaded), .dismiss)
        XCTAssertEqual(flow.state, .available(release))
    }

    /// Sparkle ended the session while installing, without an error: the update is offered
    /// again rather than shown installing forever.
    func testAbortedInstallGoesBackToOffered() {
        let (flow, _) = makeFlow()
        _ = flow.found(release, stage: .notDownloaded)
        _ = flow.requestInstall()
        flow.downloadStarted()
        flow.sessionEnded()
        XCTAssertEqual(flow.state, .available(release))
        XCTAssertFalse(flow.installRequested)

        flow.checkStarted()
        XCTAssertEqual(flow.state, .checking)
        flow.sessionEnded()
        XCTAssertEqual(flow.state, .idle)
    }

    func testOnChangeFiresOnlyOnChange() {
        let (flow, seen) = makeFlow()
        flow.checkStarted()
        flow.checkStarted()
        _ = flow.found(release, stage: .notDownloaded)
        _ = flow.found(release, stage: .notDownloaded)
        XCTAssertEqual(seen(), [.checking, .available(release)])
    }
}
