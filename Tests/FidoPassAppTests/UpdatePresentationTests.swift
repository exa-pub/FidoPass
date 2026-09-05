import AppKit
import Combine
import XCTest
@testable import FidoPassAppKit

/// What the app shows for an update: a dot, a menu item, a line in Preferences — and no window.
@MainActor
final class UpdatePresentationTests: AppTestCase {

    private let release = UpdateCandidate(version: "0.19.0", build: "0.19.0",
                                          releaseNotesURL: URL(string: "https://example.org/notes"))

    // MARK: - State

    func testOnlyOfferedStatesShowTheDotAndAnEnabledMenuItem() {
        let offered: [UpdateState] = [.available(release), .readyToInstall(release)]
        for state in offered {
            XCTAssertTrue(state.offersInstall)
            XCTAssertFalse(state.isInstalling)
            XCTAssertEqual(state.menuTitle, "• Update to 0.19.0…")
            XCTAssertTrue(StatusItemIcon.badgeVisible(for: .unlocked, updateOffered: state.offersInstall))
        }
        let busy: [UpdateState] = [.downloading(release, fraction: 0.4), .installing(release)]
        for state in busy {
            XCTAssertFalse(state.offersInstall)
            XCTAssertTrue(state.isInstalling)
            XCTAssertEqual(state.menuTitle, "Installing 0.19.0…")
        }
        let quiet: [UpdateState] = [.idle, .checking, .upToDate(checkedAt: Date()), .failed(message: "x", at: Date())]
        for state in quiet {
            XCTAssertFalse(state.offersInstall)
            XCTAssertNil(state.menuTitle, "\(state) must not appear in the menu")
            XCTAssertFalse(StatusItemIcon.badgeVisible(for: .unlocked, updateOffered: state.offersInstall))
        }
    }

    /// The clipboard dot and the update dot share one slot; neither hides the other.
    func testTheClipboardDotAndTheUpdateDotCoexist() {
        XCTAssertTrue(StatusItemIcon.badgeVisible(for: .clipboardHot, updateOffered: false))
        XCTAssertTrue(StatusItemIcon.badgeVisible(for: .clipboardHot, updateOffered: true))
        XCTAssertFalse(StatusItemIcon.badgeVisible(for: .locked, updateOffered: false))
        XCTAssertEqual(StatusItemIcon.tooltip(for: .locked, update: nil), StatusItemIcon.description(for: .locked))
        XCTAssertEqual(StatusItemIcon.tooltip(for: .clipboardHot, update: "0.19.0"),
                       "FidoPass — a secret is on the clipboard · update 0.19.0 available")
    }

    // MARK: - Version

    func testVersionDisplayDistinguishesReleasesFromBuildsAfterThem() {
        XCTAssertTrue(AppVersion(short: "0.18.0", build: "0.18.0", commit: "6c62edf").isRelease)
        XCTAssertEqual(AppVersion(short: "0.18.0", build: "0.18.0", commit: "6c62edf").display, "0.18.0")
        let dev = AppVersion(short: "0.17.0-dev.8", build: "0.17.0.8", commit: "36a05a1")
        XCTAssertFalse(dev.isRelease)
        XCTAssertEqual(dev.display, "0.17.0-dev.8 (36a05a1)")
        XCTAssertFalse(AppVersion(short: "dev", build: "dev").isRelease)
        XCTAssertEqual(AppVersion(bundle: Bundle(for: UpdatePresentationTests.self)).short.isEmpty, false)
    }

    func testInstallLocationExplainsWhySparkleWouldStaySilent() {
        XCTAssertNil(InstallLocation.updateHint(for: URL(fileURLWithPath: "/Applications/FidoPass.app")))
        XCTAssertNotNil(InstallLocation.updateHint(for: URL(fileURLWithPath: "/Volumes/FidoPass/FidoPass.app")))
        XCTAssertNotNil(InstallLocation.updateHint(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/FidoPass.app")))
    }

    // MARK: - Model

    func testModelMirrorsTheServiceAndForwardsTheSwitches() {
        let service = MockUpdateService(available: true)
        let model = UpdateModel(service: service, bundleURL: URL(fileURLWithPath: "/Applications/FidoPass.app"))
        XCTAssertTrue(model.isAvailable)
        XCTAssertNil(model.installHint)
        XCTAssertEqual(model.statusText, "Not checked yet")

        service.send(.checking)
        XCTAssertEqual(model.statusText, "Checking…")
        service.send(.available(release))
        XCTAssertEqual(model.statusText, "0.19.0 is available")
        service.send(.downloading(release, fraction: 0.5))
        XCTAssertEqual(model.statusText, "Downloading 0.19.0… 50%")
        service.send(.downloading(release, fraction: nil))
        XCTAssertEqual(model.statusText, "Preparing 0.19.0…")
        service.send(.readyToInstall(release))
        XCTAssertEqual(model.statusText, "0.19.0 is downloaded and verified")
        service.send(.installing(release))
        XCTAssertEqual(model.statusText, "Installing 0.19.0…")
        service.send(.failed(message: "The update could not be downloaded.", at: Date()))
        XCTAssertEqual(model.statusText, "The update could not be downloaded.")
        service.send(.upToDate(checkedAt: Date()))
        XCTAssertTrue(model.statusText.hasPrefix("Up to date"))

        model.automaticallyChecks = false
        model.automaticallyDownloads = true
        XCTAssertFalse(service.automaticallyChecks)
        XCTAssertTrue(service.automaticallyDownloads)
        model.checkNow()
        model.install()
        XCTAssertEqual(service.checks, 1)
        XCTAssertEqual(service.installs, 1)
    }

    func testModelWarnsAboutADiskImageOnlyWhenUpdatesArePossible() {
        let dmg = URL(fileURLWithPath: "/Volumes/FidoPass/FidoPass.app")
        XCTAssertNotNil(UpdateModel(service: MockUpdateService(available: true), bundleURL: dmg).installHint)
        XCTAssertNil(UpdateModel(service: MockUpdateService(available: false), bundleURL: dmg).installHint)
    }

    // MARK: - Menus

    func testTheApplicationMenuOffersACheck() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        let delegate = AppDelegate(updates: MockUpdateService(available: true))
        delegate.installMainMenu()
        let appMenu = app.mainMenu?.items.first?.submenu
        let item = appMenu?.items.first { $0.title == "Check for Updates…" }
        XCTAssertNotNil(item)
        XCTAssertTrue(item?.target === delegate)
        XCTAssertEqual(appMenu?.items.firstIndex { $0.title == "Check for Updates…" }, 1, "right after About")
    }

    /// The container tells the updater when a relaunch may happen: never during a key operation.
    func testRelaunchWaitsForTheKey() async {
        let service = MockUpdateService(available: true)
        let backend = MockKeyBackend()
        let container = AppTestFactory.makeContainer(backend: backend, updates: service)
        XCTAssertEqual(service.canRelaunchNow?(), true)

        let gate = BlockingGate()
        let task = Task {
            try? await container.touchGate.withBusy("Reading") {
                await Task.detached { gate.wait() }.value
            }
        }
        try? await waitUntil { container.touchGate.isWorking }
        XCTAssertEqual(service.canRelaunchNow?(), false)
        gate.open()
        await task.value
        try? await waitUntil { !container.touchGate.isWorking }
        XCTAssertEqual(service.canRelaunchNow?(), true)
        try? await waitUntil { service.gateOpenings >= 1 }
        XCTAssertGreaterThanOrEqual(service.gateOpenings, 1)
    }
}

@MainActor
final class MockUpdateService: UpdateService {
    let isAvailable: Bool
    let currentVersion = AppVersion(short: "0.18.0", build: "0.18.0", commit: "abc1234")
    private let subject = CurrentValueSubject<UpdateState, Never>(.idle)
    var state: UpdateState { subject.value }
    var statePublisher: AnyPublisher<UpdateState, Never> { subject.eraseToAnyPublisher() }
    var automaticallyChecks = true
    var automaticallyDownloads = false
    var lastCheck: Date?
    var canRelaunchNow: (@MainActor () -> Bool)?
    private(set) var checks = 0
    private(set) var installs = 0
    private(set) var gateOpenings = 0

    init(available: Bool) { isAvailable = available }

    func send(_ state: UpdateState) { subject.send(state) }
    func checkForUpdates() { checks += 1 }
    func install() { installs += 1 }
    func relaunchGateDidOpen() { gateOpenings += 1 }
}
