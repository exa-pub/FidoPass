import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

@MainActor
final class AppReviewRegressionTests: AppTestCase {
    func testNewEnrollmentAttemptReplacesItsOwnErrorInEveryMode() async {
        for mode in EnrollDraft.Mode.allCases {
            let (panel, backend, _) = await AppTestFactory.unlockedStore()
            panel.show(.enroll)
            panel.enrollDraft.mode = mode
            panel.enrollDraft.accountId = "backup"
            if mode == .import { panel.enrollDraft.importText = backend.backupValue.base64 }
            backend.enrollError = FidoPassError.invalidState("Account already exists")
            await panel.createAccount()
            XCTAssertNotNil(panel.error)
            backend.enrollError = nil
            panel.enrollDraft.accountId = "archive"
            await panel.createAccount()
            XCTAssertNil(panel.error)
            XCTAssertTrue(panel.visibleAccounts.contains { $0.id == "archive" })
            panel.show(.enroll)
            panel.enrollDraft.accountId = "next"
            backend.enrollError = FidoPassError.invalidState("A different failure")
            await panel.createAccount()
            XCTAssertNotNil(panel.error)
        }
    }

    func testStatusResponseCannotChangeAnotherKeysForm() async throws {
        let backend = MockKeyBackend()
        let first = MockKeyBackend.device(path: "first")
        let second = MockKeyBackend.device(path: "second")
        backend.devices = [first, second]
        backend.statusByPath[first.path] = DeviceStatus(pinRetriesRemaining: nil, hasPIN: false,
            supportsHmacSecret: true, remainingResidentKeys: 2)
        let panel = AppTestFactory.makeStore(backend: backend)
        await panel.devices.refresh()
        panel.selectKey(path: first.path)
        let gate = BlockingGate()
        backend.statusGate = gate
        defer { gate.open() }
        panel.pinDraft = "1"
        let checking = Task { await panel.pinDraftDidChange() }
        try await waitUntil { gate.hasEntered }
        panel.selectKey(path: second.path)
        gate.open()
        await checking.value
        XCTAssertEqual(panel.effectiveRoute, .unlock)
        XCTAssertNil(panel.devices.state(for: second.path)?.hasPIN)
        XCTAssertFalse(panel.isCheckingPINStatus)
        XCTAssertTrue(panel.pinDraft.isEmpty)
    }

    func testFailedStatusCanBeExplicitlyRetriedWithoutAuthenticating() async {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.statusError = FidoPassError.invalidState("Disconnected")
        let panel = AppTestFactory.makeStore(backend: backend)
        await panel.devices.refresh()
        panel.pinDraft = "1"
        await panel.pinDraftDidChange()
        XCTAssertNotNil(panel.error)
        backend.statusError = nil
        await panel.checkPINStatus()
        XCTAssertNotNil(panel.devices.selectedState?.hasPIN)
        XCTAssertEqual(backend.statusCallCount, 2)
        XCTAssertEqual(backend.enumerateCallCount, 0)
    }

    func testManagerContextKeepsUnfinishedFormBoundToItsKey() async throws {
        let (panel, backend, first) = await AppTestFactory.unlockedStore()
        let second = MockKeyBackend.device(path: "second")
        backend.devices = [first, second]
        backend.pins[second.path] = "1234"
        await panel.devices.refresh()
        let manager = AppTestFactory.manager(for: panel)
        await manager.managerDidOpen(devicePath: first.path)
        manager.beginChangePIN()
        manager.pinForm.current = "1234"
        manager.pinForm.new = "5678"
        manager.pinForm.confirm = "5678"
        panel.selectKey(path: second.path)
        panel.openManager()
        XCTAssertEqual((panel.router as? RecordingWindowRouter)?.managerPaths.last!, second.path)
        let reads = backend.inspectCallCount
        await manager.managerDidOpen(devicePath: second.path)
        XCTAssertEqual(manager.device?.path, first.path)
        XCTAssertEqual(manager.pinForm.boundPath, first.path)
        XCTAssertNotNil(manager.notice)
        XCTAssertEqual(backend.inspectCallCount, reads)
        manager.cancelChangePIN()
        await manager.managerDidOpen(devicePath: second.path)
        XCTAssertEqual(manager.device?.path, second.path)
    }

    func testDisconnectedManagerDoesNotSelectANamesakeOrApplyOldConfirmation() async {
        let (panel, backend, first) = await AppTestFactory.unlockedStore()
        let manager = AppTestFactory.manager(for: panel)
        await manager.managerDidOpen(devicePath: first.path)
        let replacement = MockKeyBackend.device(path: "replacement", product: first.product)
        backend.devices = [replacement]
        await panel.devices.refresh()
        XCTAssertNil(manager.device)
        XCTAssertNil(manager.chosenPath)
        XCTAssertNotNil(manager.notice)
        await manager.forcePINChange(expectedPath: first.path)
        XCTAssertTrue(backend.configCalls.isEmpty)
    }

    func testCapacityHintExpiresAndMutationsInvalidateIt() async {
        let (panel, backend, device) = await AppTestFactory.unlockedStore()
        backend.infoByPath[device.path] = MockKeyBackend.info(remainingResidentKeys: 0)
        backend.inventoryByPath[device.path] = CredentialInventory(relyingParties: [], residentKeysUsed: 2, residentKeysRemaining: 0, largeBlobArrayBytes: nil)
        await panel.inventory.read(device)
        panel.enrollDraft.accountId = "new"
        panel.enrollDraft.mode = .local
        await panel.createAccount()
        XCTAssertTrue(backend.enrollCalls.isEmpty, "known full key must fail before Touch/backend")
        XCTAssertNil(panel.inventory.knownFreeSlots(on: device.path, now: Date().addingTimeInterval(31)))
        panel.inventory.invalidateCapacity(on: device.path)
        await panel.createAccount()
        XCTAssertEqual(backend.enrollCalls.count, 1, "unknown capacity is validated by the authenticator")
        XCTAssertNil(panel.inventory.knownFreeSlots(on: device.path))
    }

    func testWindowPlacementFitsDifferentScreensAndAvoidsWelcome() {
        for visible in [CGRect(x: 0, y: 70, width: 1280, height: 690),
                        CGRect(x: -1600, y: 0, width: 1600, height: 900)] {
            let offscreen = CGRect(x: visible.maxX - 100, y: visible.minY - 100, width: 640, height: 1000)
            XCTAssertTrue(visible.contains(WindowPlacement.clamped(offscreen, to: visible)))
            let welcome = CGRect(x: visible.midX - 230, y: visible.midY - 210, width: 460, height: 420)
            let tool = WindowPlacement.beside(welcome, size: CGSize(width: 610, height: 300), in: visible)
            XCTAssertTrue(visible.contains(tool))
            XCTAssertFalse(tool.intersects(welcome))
        }
    }
}
