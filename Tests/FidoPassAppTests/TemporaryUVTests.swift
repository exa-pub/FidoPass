import Foundation
import XCTest
import FidoPassCore
@testable import FidoPassAppKit

final class TemporaryUVTests: AppTestCase {
    @MainActor
    private func fixture(duration: Duration = .seconds(60)) async -> (AppContainer, MockKeyBackend, FidoDevice) {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.alwaysUVByPath[device.path] = true
        let app = AppTestFactory.makeContainer(backend: backend, temporaryUVDuration: duration)
        await app.panel.prepareForDisplay()
        app.panel.pinDraft = "1234"
        await app.panel.submitPin()
        XCTAssertTrue(app.panel.isSelectedKeyUnlocked)
        return (app, backend, device)
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    @MainActor
    func testTimerSurvivesClosedHUDAndDoesNotRestartOnAnotherClick() async {
        let (app, backend, device) = await fixture(duration: .milliseconds(100))
        await app.temporaryUV.start(for: device)
        let deadline = app.temporaryUV.deadline
        await app.temporaryUV.start(for: device)
        app.panel.panelDidClose()
        XCTAssertEqual(app.temporaryUV.deadline, deadline)
        await eventually { app.temporaryUV.phase == .idle }
        XCTAssertEqual(backend.configCalls, ["setAlwaysUV(false)", "setAlwaysUV(true)"])
        XCTAssertEqual(backend.alwaysUVByPath[device.path], true)
    }

    @MainActor
    func testAlreadyOffAndFailedDisableDoNotStartTimer() async {
        let (app, backend, device) = await fixture()
        backend.alwaysUVByPath[device.path] = false
        await app.temporaryUV.start(for: device)
        XCTAssertNil(app.temporaryUV.device)
        XCTAssertNil(app.temporaryUV.deadline)
        XCTAssertEqual(backend.alwaysUVByPath[device.path], false)
        backend.alwaysUVByPath[device.path] = true
        await app.devices.refreshStatus(for: device)
        backend.configError = FidoPassError.unsupported("Configuration unavailable")
        await app.temporaryUV.start(for: device)
        XCTAssertNil(app.temporaryUV.device)
        XCTAssertNil(app.temporaryUV.deadline)
        XCTAssertNotNil(app.temporaryUV.error)
    }

    @MainActor
    func testFailedRestoreCanBeRetriedManuallyWithoutBlindToggle() async {
        let (app, backend, device) = await fixture()
        await app.temporaryUV.start(for: device)
        backend.configErrorAfterMutation = CocoaError(.fileReadUnknown)
        await app.temporaryUV.restore()
        XCTAssertEqual(app.temporaryUV.phase, .paused)
        XCTAssertNotNil(app.temporaryUV.error)
        XCTAssertNil(app.temporaryUV.deadline, "No automatic authenticated retry after a failed attempt")
        XCTAssertEqual(backend.alwaysUVByPath[device.path], true)
        await app.temporaryUV.restore()
        XCTAssertEqual(app.temporaryUV.phase, .idle)
        XCTAssertEqual(backend.alwaysUVByPath[device.path], true)
    }

    @MainActor
    func testDisconnectForgetsPauseAndReplugDoesNothing() async {
        let (app, backend, device) = await fixture(duration: .milliseconds(100))
        await app.temporaryUV.start(for: device)
        let deadline = app.temporaryUV.deadline!
        backend.devices = []
        await app.devices.refresh()
        XCTAssertNil(app.temporaryUV.device)
        XCTAssertNil(app.temporaryUV.deadline)
        XCTAssertNil(app.temporaryUV.error)
        backend.devices = [device]
        await app.devices.refresh()
        try? await ContinuousClock().sleep(until: deadline.advanced(by: .milliseconds(20)))
        XCTAssertEqual(app.temporaryUV.phase, .idle)
        XCTAssertEqual(backend.configCalls, ["setAlwaysUV(false)"])
        XCTAssertEqual(backend.alwaysUVByPath[device.path], false)
    }

    @MainActor
    func testLockForgetsPauseEvenDuringNativeRestore() async {
        let (app, backend, device) = await fixture()
        await app.temporaryUV.start(for: device)
        let block = BlockingGate()
        backend.configGate = block
        let restore = Task { await app.temporaryUV.restore() }
        await eventually { block.hasEntered }
        app.panel.lockSelectedKey()
        XCTAssertFalse(app.panel.isSelectedKeyUnlocked)
        XCTAssertNil(app.temporaryUV.device)
        XCTAssertTrue(app.touchGate.isWorking, "The existing gate still owns the native call")
        block.open()
        await restore.value
        XCTAssertEqual(app.temporaryUV.phase, .idle)
        XCTAssertNil(app.temporaryUV.error, "A late result cannot resurrect forgotten state")
    }

    @MainActor
    func testPINRejectionForgetsPauseAndDoesNotRetry() async {
        let (app, backend, device) = await fixture()
        await app.temporaryUV.start(for: device)
        backend.pins[device.path] = "5678"
        await app.temporaryUV.restore()
        await app.temporaryUV.restore()
        XCTAssertFalse(app.panel.isSelectedKeyUnlocked)
        XCTAssertEqual(app.temporaryUV.phase, .idle)
        XCTAssertEqual(backend.configCalls, ["setAlwaysUV(false)", "setAlwaysUV(true)"])
    }

    @MainActor
    func testBusyGateDefersTimerWithoutChangingQueueOwnership() async {
        let (app, backend, device) = await fixture(duration: .milliseconds(100))
        await app.temporaryUV.start(for: device)
        let deadline = app.temporaryUV.deadline!
        let block = BlockingGate()
        backend.statusGate = block
        let read = Task {
            try await app.touchGate.withBusy("Read") { await app.devices.refreshStatus(for: device) }
        }
        await eventually { block.hasEntered }
        try? await ContinuousClock().sleep(until: deadline.advanced(by: .milliseconds(20)))
        XCTAssertEqual(backend.configCalls, ["setAlwaysUV(false)"])
        app.touchGate.abandonTouch()
        XCTAssertTrue(app.touchGate.isWorking)
        block.open()
        _ = try? await read.value
        await eventually { app.temporaryUV.phase == .idle }
        XCTAssertEqual(backend.configCalls, ["setAlwaysUV(false)", "setAlwaysUV(true)"])
    }

    @MainActor
    func testManagerPermanentSettingReplacesPause() async {
        let (app, backend, device) = await fixture()
        await app.manager.managerDidOpen(devicePath: device.path)
        await app.temporaryUV.start(for: device)
        await app.manager.setAlwaysUV(false)
        XCTAssertNil(app.temporaryUV.device)
        XCTAssertNil(app.temporaryUV.deadline)
        XCTAssertEqual(app.manager.reading.info?.alwaysUV, false)
        XCTAssertEqual(backend.alwaysUVByPath[device.path], false)
    }

    @MainActor
    func testMenuTracksManagerSettingAfterDeviceRefreshAndHUDReopen() async {
        let (app, backend, device) = await fixture()
        await app.manager.managerDidOpen(devicePath: device.path)
        await app.manager.setAlwaysUV(false)
        app.panel.panelDidClose()
        await app.panel.prepareForDisplay()
        XCTAssertNil(app.temporaryUV.menuTitle(for: device))

        await app.manager.setAlwaysUV(true)
        let reads = backend.statusCallCount
        await app.devices.refresh()
        app.panel.panelDidClose()
        await app.panel.prepareForDisplay()

        XCTAssertEqual(app.devices.state(for: device.path)?.alwaysUV, true)
        XCTAssertEqual(app.devices.state(for: device.path)?.supportsConfiguration, true)
        XCTAssertEqual(app.temporaryUV.menuTitle(for: device), "Pause Require UV for 1 minute")
        XCTAssertTrue(app.temporaryUV.canPerformAction(for: device))
        XCTAssertEqual(backend.statusCallCount, reads, "Refreshing the device list must not open the key")
    }

    @MainActor
    func testPINExpiryShortensPauseAndRestoreDoesNotRenewPIN() async {
        let (app, _, device) = await fixture()
        app.devices.setPinTTL(60)
        await app.temporaryUV.start(for: device)
        XCTAssertLessThanOrEqual(app.temporaryUV.remainingSeconds(), 55)
        let expiration = app.devices.pinExpiration(for: device.path)
        await app.temporaryUV.restore()
        XCTAssertEqual(app.devices.pinExpiration(for: device.path), expiration)
    }

    @MainActor
    func testSelectionAndMenuDoNotChangeThePauseOwnerOrOpenDevices() async {
        let (app, backend, device) = await fixture()
        let other = MockKeyBackend.device(path: "/dev/two")
        backend.devices.append(other)
        await app.devices.refresh()
        await app.temporaryUV.start(for: device)
        app.panel.selectKey(path: other.path)
        let reads = backend.statusCallCount
        _ = app.temporaryUV.menuTitle(for: other)
        _ = app.temporaryUV.canPerformAction(for: other)
        XCTAssertEqual(backend.statusCallCount, reads)
        await app.temporaryUV.restore()
        XCTAssertEqual(backend.alwaysUVByPath[device.path], true)
        XCTAssertNil(backend.alwaysUVByPath[other.path])
        app.temporaryUV.stop()
        let fresh = AppTestFactory.makeContainer(backend: backend)
        XCTAssertNil(fresh.temporaryUV.device)
    }
}
