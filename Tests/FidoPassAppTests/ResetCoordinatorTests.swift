import Combine
import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// Erasing the key. What is asserted here is mostly what must *not* happen: the wrong key
/// not erased, a cancelled wizard not firing, state not left behind.
@MainActor
final class ResetCoordinatorTests: AppTestCase {

    private func armedReset() async throws -> (PanelStore, MockKeyBackend, FidoDevice, ResetCoordinator) {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        AppTestFactory.seedLabels(store, ["work"])
        let reset = AppTestFactory.reset(for: store)
        try await reset.begin(device: device)
        reset.flow?.acknowledged = true
        reset.flow?.typed = "RESET"
        reset.arm()
        return (store, backend, device, reset)
    }

    /// After the reconnect the path is different and a vendor signature only names a model.
    /// With two keys present there is no way left to tell which one came back.
    func testResetRefusesToStartWithTwoKeysConnected() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        backend.devices.append(MockKeyBackend.device(path: "/dev/two"))
        await store.devices.refresh()
        let reset = AppTestFactory.reset(for: store)

        do {
            try await reset.begin(device: device)
            XCTFail("two keys must be refused")
        } catch let refusal as ResetCoordinator.Refusal {
            XCTAssertEqual(refusal.errorDescription?.isEmpty, false)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertNil(reset.flow)
    }

    /// The manager turns that refusal into its own message — never the panel's.
    func testTheManagerReportsTheRefusal() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        backend.devices.append(MockKeyBackend.device(path: "/dev/two"))
        await store.devices.refresh()
        let manager = AppTestFactory.manager(for: store)

        await manager.beginReset()

        XCTAssertNotNil(manager.settingsError)
        XCTAssertNil(manager.sheet)
        XCTAssertNil(store.error)
    }

    /// A local account cannot be recovered by any means, so a checkbox is not enough.
    func testAKeyHoldingALocalAccountAsksForTheWordToBeTyped() async throws {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let reset = AppTestFactory.reset(for: store)
        try await reset.begin(device: device)
        reset.flow?.acknowledged = true

        XCTAssertEqual(reset.flow?.requiresTypedConfirmation, true)
        XCTAssertEqual(reset.flow?.canProceed, false)
        reset.flow?.typed = "RESET"
        XCTAssertEqual(reset.flow?.canProceed, true)
    }

    func testTheKeyComingBackRunsTheResetAndLandsInBootstrap() async throws {
        let (store, backend, device, reset) = try await armedReset()

        backend.devices = []
        await store.devices.refresh()
        XCTAssertEqual(reset.flow?.stage, .replug)

        backend.devices = [device]
        await store.devices.refresh()
        await reset.task?.value

        XCTAssertEqual(backend.resetCalls, [device.path])
        XCTAssertNil(reset.flow)
        XCTAssertEqual(store.devices.state(for: device.path)?.hasPIN, false)
        XCTAssertEqual(store.effectiveRoute, .setPIN,
                       "a key with no PIN is unusable, and an empty account list would be the old dead end")
        XCTAssertNotNil(store.statusText, "the panel says what happened")
    }

    /// The wizard is a sheet in the manager window, so that is where the touch prompt goes —
    /// the panel neither shows it nor is held open by it.
    func testTheTouchPromptBelongsToTheManager() async throws {
        let (store, backend, device, reset) = try await armedReset()
        let gate = store.touchGate
        var surfaces: [TouchSurface] = []
        let watching = gate.$prompt.sink { prompt in
            if prompt != nil { surfaces.append(gate.surface) }
        }

        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()
        await reset.task?.value
        watching.cancel()

        XCTAssertEqual(surfaces, [.manager])
        XCTAssertNil(store.touch, "and nothing is left on the panel afterwards")
    }

    /// The credential ids these histories are keyed by will never exist again.
    func testResetForgetsWhatCanNeverBeAskedForAgain() async throws {
        let (store, backend, device, reset) = try await armedReset()
        XCTAssertFalse(store.labels.histories.isEmpty)

        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()
        await reset.task?.value

        XCTAssertTrue(store.labels.histories.isEmpty)
        XCTAssertNil(store.preferences.lastUsed)
        XCTAssertTrue(store.accounts.accounts.isEmpty)
    }

    /// A matching AAGUID proves nothing, but a differing one proves the key is not the same —
    /// and erasing the wrong key is not a recoverable mistake.
    func testADifferentKeyComingBackIsNotErased() async throws {
        let (store, backend, device, reset) = try await armedReset()

        backend.devices = []
        await store.devices.refresh()
        backend.aaguid = "ff" + String(repeating: "00", count: 15)
        backend.devices = [device]
        await store.devices.refresh()
        await reset.task?.value

        XCTAssertNotNil(reset.error)
        XCTAssertEqual(reset.flow?.stage, .retry, "retry requires a fresh explicit authorization")
        XCTAssertEqual(backend.pins[device.path], "1234", "the key still has its PIN, so nothing was erased")
        XCTAssertFalse(backend.accountsByPath[device.path, default: []].isEmpty)
    }

    /// Fetching a backup key is the one legitimate detour out of this wizard — it is the last
    /// moment that value can be had. The wizard is a sheet in the manager window, so the panel
    /// is free to go wherever the user sends it — what must not happen is the flow quietly
    /// disappearing while it is still armed.
    func testFetchingABackupKeyDoesNotAbandonAnArmedReset() async throws {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let reset = AppTestFactory.reset(for: store)
        try await reset.begin(device: device)
        guard let portable = reset.flow?.doomed.first(where: { $0.kind == .portable }) else {
            return XCTFail("the fixture is supposed to have a portable account")
        }

        await store.showBackupKey(for: portable.ref)
        XCTAssertEqual(store.route, .backupKey(portable.ref))

        store.backToAccounts()
        XCTAssertEqual(store.route, .accounts)
        XCTAssertNotNil(reset.flow, "the wizard is in another window and outlives this one")
    }

    /// A user who unplugged the key and then thought better of it must not be held in the
    /// wizard. Only the erase itself is past the point of cancelling.
    func testTheWizardCanBeCancelledUntilTheKeyIsBeingErased() async throws {
        let (store, backend, device, reset) = try await armedReset()

        backend.devices = []
        await store.devices.refresh()
        XCTAssertEqual(reset.flow?.stage, .replug)

        reset.cancel()
        XCTAssertNil(reset.flow)
        XCTAssertNil(store.devices.armedReset)

        backend.devices = [device]
        await store.devices.refresh()
        await reset.task?.value
        XCTAssertTrue(backend.resetCalls.isEmpty, "a cancelled wizard must not still fire")
    }

    /// The acknowledgement is waived only for a key that is *known* to hold nothing. A locked
    /// key enumerates to an empty list precisely because its contents are unknown, and waiving
    /// the warning there would skip it in the one case where the user knows least about what
    /// they are erasing. It used to be waived on any empty list, which also left the checkbox
    /// on screen doing nothing.
    func testAcknowledgementIsOnlyWaivedForAKeyKnownToBeEmpty() {
        var unreadable = ResetFlow(deviceName: "Key", expectedAAGUID: nil,
                                   doomed: [], accountsReadable: false, scopes: [])
        XCTAssertFalse(unreadable.isKnownEmpty)
        XCTAssertFalse(unreadable.canProceed, "an unreadable key still needs the warning read")
        unreadable.acknowledged = true
        XCTAssertTrue(unreadable.canProceed)

        let empty = ResetFlow(deviceName: "Key", expectedAAGUID: nil,
                              doomed: [], accountsReadable: true, scopes: [])
        XCTAssertFalse(empty.isKnownEmpty, "An empty FidoPass list says nothing about other credentials")
        XCTAssertFalse(empty.canProceed, "Erasing every credential always requires acknowledgement")
    }

    /// The wizard tells the user to unplug the key. When they do, the flow must survive the
    /// key being gone — that absence is the step, not a failure.
    func testTheWizardSurvivesTheKeyBeingOut() async throws {
        let (store, backend, _, reset) = try await armedReset()

        backend.devices = []
        await store.devices.refresh()

        XCTAssertNotNil(reset.flow)
        XCTAssertEqual(reset.flow?.stage, .replug)
    }

    /// Closing the panel must **not** disarm the reset: the wizard lives in the manager window,
    /// and that window taking focus is what closes the panel. Disarming there would cancel the
    /// flow at the exact moment the user went to drive it.
    func testClosingThePanelLeavesTheResetArmed() async throws {
        let (store, backend, device, reset) = try await armedReset()

        store.panelDidClose()

        XCTAssertNotNil(reset.flow)
        XCTAssertNotNil(store.devices.armedReset)

        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()
        await reset.task?.value

        XCTAssertEqual(backend.resetCalls, [device.path], "the flow the user armed still runs")
    }

    /// The arming still has to expire on its own, or a reset nobody is watching would fire on
    /// whatever key is plugged in next. That timeout lives in `DeviceStore.armReset`.
    func testCancellingDisarmsTheReset() async throws {
        let (store, backend, device, reset) = try await armedReset()

        reset.cancel()
        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()
        await reset.task?.value

        XCTAssertTrue(backend.resetCalls.isEmpty)
        XCTAssertNil(store.devices.armedReset)
    }
}

@MainActor
extension ResetCoordinatorTests {
    func testResetFailureMustOfferAnArmedRetry() async throws {
        let (panel, backend, device) = await AppTestFactory.unlockedStore()
        let reset = AppTestFactory.reset(for: panel)
        try await reset.begin(device: device)
        reset.flow?.acknowledged = true
        reset.flow?.typed = "RESET"
        reset.arm()
        backend.resetError = FidoPassError.invalidState("synthetic timeout")
        reset.armedKeyAppeared(device)
        await reset.task?.value
        XCTAssertEqual(reset.flow?.stage, .retry)
        XCTAssertNil(panel.devices.armedReset)
        reset.retry()
        XCTAssertNotNil(panel.devices.armedReset)
        XCTAssertEqual(reset.flow?.stage, .unplug)
        reset.cancel()
    }
}
