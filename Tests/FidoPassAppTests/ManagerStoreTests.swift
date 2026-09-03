import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// The manager window: when it reads the key, and the PIN change it hosts.
@MainActor
final class ManagerStoreTests: XCTestCase {

    // MARK: - Reading

    /// Opening the window is the request to read; the window merely existing is not.
    func testOpeningTheWindowReadsTheKeyOnce() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)

        await manager.deviceDidAppear()
        XCTAssertEqual(backend.inspectCallCount, 1)
        XCTAssertEqual(backend.inventoryCallCount, 1, "unlocked, so the credentials come too")

        await manager.deviceDidAppear()
        XCTAssertEqual(backend.inspectCallCount, 1, "a second appearance of the same key reads nothing")
    }

    /// ⌘R is a deliberate re-read and always reads.
    func testAnExplicitReadAlwaysReads() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)

        await manager.read()
        await manager.read()

        XCTAssertEqual(backend.inspectCallCount, 2)
    }

    /// A reset makes the key reappear on a new path — exactly what re-triggers the read. Reading
    /// then would seize the device in the seconds-wide window where the reset has to be issued.
    func testNothingIsReadWhileAResetIsArmed() async throws {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        try await manager.reset.begin(device: device)
        manager.reset.flow?.acknowledged = true
        manager.reset.flow?.typed = "RESET"
        manager.reset.arm()
        let before = backend.inspectCallCount

        await manager.deviceDidAppear()

        XCTAssertEqual(backend.inspectCallCount, before)
    }

    /// Unlocking sends the user to the panel — the manager has no PIN field of its own.
    func testUnlockingGoesThroughThePanel() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        let router = store.router as! RecordingWindowRouter

        manager.requestUnlock()

        XCTAssertEqual(router.panelOpened, 1)
        XCTAssertEqual(store.devices.selectedPath, device.path)
    }

    // MARK: - Changing the PIN

    func testChangingThePinAdoptsTheNewOneAndClosesTheSheet() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        manager.beginChangePIN()
        XCTAssertEqual(manager.sheet, .changePIN)
        manager.pinForm.current = "1234"
        manager.pinForm.new = "567890"
        manager.pinForm.confirm = "567890"

        await manager.changePIN()

        XCTAssertEqual(backend.changePINCalls.count, 1)
        XCTAssertEqual(backend.pins[device.path], "567890")
        XCTAssertEqual(store.devices.pin(for: device.path), "567890",
                       "the vault must hold the PIN that now opens the key, not the one that does not")
        XCTAssertTrue(store.isSelectedKeyUnlocked)
        XCTAssertTrue(manager.pinForm.isEmpty)
        XCTAssertNil(manager.sheet, "accepted, so the sheet comes down")
        XCTAssertNil(manager.pinError)
    }

    /// A typo in this form must not cost access that the old PIN still grants.
    func testAWrongCurrentPinLeavesTheVaultAloneAndTheSheetUp() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        manager.beginChangePIN()
        manager.pinForm.current = "9999"
        manager.pinForm.new = "567890"
        manager.pinForm.confirm = "567890"

        await manager.changePIN()

        XCTAssertEqual(backend.pins[device.path], "1234", "the key's PIN is unchanged")
        XCTAssertEqual(store.devices.pin(for: device.path), "1234")
        XCTAssertTrue(store.isSelectedKeyUnlocked, "the old PIN still works, so access is not lost")
        XCTAssertNotNil(manager.pinError)
        XCTAssertEqual(manager.sheet, .changePIN, "closing would hide the attempts count")
        XCTAssertEqual(manager.pinForm.new, "567890", "retyping a new PIN that was fine is busywork")
        XCTAssertEqual(manager.pinForm.current, "", "the failure was about the old one")
    }

    /// The point of validating locally: an attempt spent on a new PIN that was never going to
    /// be accepted is an attempt spent for nothing, and there are only eight.
    func testAnInvalidNewPinCostsNoAttempt() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        manager.pinForm.current = "1234"
        manager.pinForm.new = "12"
        manager.pinForm.confirm = "12"

        await manager.changePIN()

        XCTAssertTrue(backend.changePINCalls.isEmpty)
    }

    func testChangingToTheSamePinIsRefusedBeforeTheKeySeesIt() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        manager.pinForm.current = "123456"
        manager.pinForm.new = "123456"
        manager.pinForm.confirm = "123456"

        XCTAssertEqual(manager.pinForm.issue, PinPolicy.Issue.sameAsOld.message)
        XCTAssertFalse(manager.pinForm.canSubmit)
    }

    /// The manager's errors are the manager's: nothing it does may write into the panel.
    func testAFailedChangeDoesNotReachThePanel() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        manager.pinForm.current = "9999"
        manager.pinForm.new = "567890"
        manager.pinForm.confirm = "567890"

        await manager.changePIN()

        XCTAssertNil(store.error)
        XCTAssertTrue(store.pinForm.isEmpty)
    }

    // MARK: - Settings

    /// `alwaysUv` is a toggle, so what the switch shows afterwards has to come from the key,
    /// not from the app's guess — every change is followed by a re-read.
    func testASettingChangeReReadsTheKey() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        let before = backend.inspectCallCount

        await manager.toggleAlwaysUV()

        XCTAssertEqual(backend.configCalls, ["toggleAlwaysUV"])
        XCTAssertEqual(backend.inspectCallCount, before + 1)
        XCTAssertNil(manager.settingsError)
        XCTAssertFalse(manager.isApplying)
    }

    func testASettingRefusedByTheKeyIsReportedHere() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: store)
        backend.configError = FidoPassError.unsupported("no such option")

        await manager.forcePINChange()

        XCTAssertNotNil(manager.settingsError)
        XCTAssertNil(store.error, "the panel has nothing to do with it")
    }
}
