import AppKit
import FidoPassAppKit
import Sparkle
import XCTest
@testable import FidoPassUpdater

/// Sparkle's callbacks, answered without a window.
@MainActor
final class HeadlessUserDriverTests: XCTestCase {

    private let release = UpdateCandidate(version: "0.19.0", build: "0.19.0")

    /// Sparkle's reply blocks are `@Sendable`; the driver calls them synchronously on the
    /// main actor, so a box read straight after the call sees the answer.
    private final class Captured<T>: @unchecked Sendable {
        var value: T?
        var count = 0
        func set(_ newValue: T) { value = newValue; count += 1 }
    }

    private func makeDriver() -> (HeadlessUserDriver, UpdateFlow) {
        let flow = UpdateFlow()
        return (HeadlessUserDriver(flow: flow), flow)
    }

    func testPermissionIsAnsweredWithoutAProfile() {
        let (driver, _) = makeDriver()
        let response = Captured<SUUpdatePermissionResponse>()
        driver.show(SPUUpdatePermissionRequest(systemProfile: []), reply: { response.set($0) })
        XCTAssertEqual(response.value?.automaticUpdateChecks, true)
        XCTAssertEqual(response.value?.sendSystemProfile, false)
    }

    func testCheckOutcomesAcknowledgeAndLandInState() {
        let (driver, flow) = makeDriver()
        let windows = NSApplication.shared.windows.count

        driver.showUserInitiatedUpdateCheck(cancellation: {})
        XCTAssertEqual(flow.state, .checking)

        let acknowledged = Captured<Bool>()
        driver.showUpdateNotFoundWithError(NSError(domain: "test", code: 1001), acknowledgement: { acknowledged.set(true) })
        XCTAssertEqual(acknowledged.count, 1)
        guard case .upToDate = flow.state else { return XCTFail("expected upToDate, got \(flow.state)") }

        let error = NSError(domain: "test", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Offline"])
        driver.showUpdaterError(error, acknowledgement: { acknowledged.set(true) })
        XCTAssertEqual(acknowledged.count, 2)
        guard case .failed(let message, _) = flow.state else { return XCTFail("expected failed, got \(flow.state)") }
        XCTAssertEqual(message, "Offline")

        XCTAssertEqual(NSApplication.shared.windows.count, windows, "no callback may open a window")
    }

    func testDownloadProgressAndReadinessInstallWithoutAsking() {
        let (driver, flow) = makeDriver()
        _ = flow.found(release, stage: .notDownloaded)
        XCTAssertTrue(flow.requestInstall())

        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 50)
        XCTAssertEqual(flow.state, .downloading(release, fraction: 0.5))
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.5)
        XCTAssertEqual(flow.state, .installing(release))

        let choice = Captured<SPUUserUpdateChoice>()
        driver.showReady(toInstallAndRelaunch: { choice.set($0) })
        XCTAssertEqual(choice.value, .install)
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        XCTAssertEqual(flow.state, .installing(release))

        let acknowledged = Captured<Bool>()
        driver.showUpdateInstalledAndRelaunched(true, acknowledgement: { acknowledged.set(true) })
        XCTAssertEqual(acknowledged.value, true)
    }

    func testDismissEndsTheSession() {
        let (driver, flow) = makeDriver()
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        driver.dismissUpdateInstallation()
        XCTAssertEqual(flow.state, .idle)
    }

    func testCandidateTakesTheBestReleaseNotesLink() {
        let empty = HeadlessUserDriver.candidate(from: SUAppcastItem.empty())
        XCTAssertNil(empty.releaseNotesURL)
        XCTAssertFalse(empty.isCritical)
    }
}
