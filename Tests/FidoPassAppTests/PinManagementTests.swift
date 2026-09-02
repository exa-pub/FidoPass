import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// Giving a key its first PIN, changing it, and erasing the key.
///
/// The three operations that act on the authenticator itself rather than on what is stored on
/// it. What is asserted here is mostly what must *not* happen: attempts not spent, vault
/// tokens not replaced, state not left behind.
@MainActor
final class PinManagementTests: XCTestCase {

    /// A key straight out of its packet: present, no PIN, nothing on it.
    private func freshKeyStore() async -> (HUDStore, MockKeyBackend, FidoDevice) {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.statusByPath[device.path] = DeviceStatus(pinRetriesRemaining: nil,
                                                         hasPIN: false,
                                                         supportsHmacSecret: true,
                                                         remainingResidentKeys: 25,
                                                         aaguid: backend.aaguid)
        let store = HUDTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()
        return (store, backend, device)
    }

    // MARK: - Bootstrap

    /// The dead end this whole flow exists to remove: the PIN screen on a key that has no PIN,
    /// whose only possible outcome was an error advising the user to set one.
    func testAKeyWithoutAPinOpensOnTheBootstrapScreen() async {
        let (store, _, _) = await freshKeyStore()
        XCTAssertEqual(store.effectiveRoute, .setPIN)
    }

    func testSettingTheFirstPinLeavesTheKeyOpen() async {
        let (store, backend, device) = await freshKeyStore()
        store.pinForm.new = "246813"
        store.pinForm.confirm = "246813"

        await store.setInitialPIN()

        XCTAssertEqual(backend.setInitialPINCalls.count, 1)
        XCTAssertEqual(backend.setInitialPINCalls.first?.pin, "246813")
        XCTAssertTrue(store.isSelectedKeyUnlocked,
                      "choosing the PIN is proof of knowing it; asking for it again reads as 'it did not hear me'")
        XCTAssertEqual(store.devices.state(for: device.path)?.hasPIN, true)
        XCTAssertEqual(store.route, .accounts)
        XCTAssertEqual(store.pinForm, HUDStore.PinForm(), "the PIN must not be left in the form")
    }

    /// Return arrives from the field and from the default button both, and this screen is where
    /// a doubled submission would set a PIN twice — the second one failing with the key
    /// refusing, on a key that is now perfectly fine.
    func testTwoSubmissionsFromOneKeypressSetOnePin() async {
        let (store, backend, _) = await freshKeyStore()
        store.pinForm.new = "246813"
        store.pinForm.confirm = "246813"

        async let first: Void = store.setInitialPIN()
        async let second: Void = store.setInitialPIN()
        _ = await (first, second)

        XCTAssertEqual(backend.setInitialPINCalls.count, 1)
    }

    func testAMismatchedRepeatCannotBeSubmitted() async {
        let (store, backend, _) = await freshKeyStore()
        store.pinForm.new = "246813"
        store.pinForm.confirm = "246812"

        XCTAssertFalse(store.canSubmitPinForm(forChange: false))
        await store.setInitialPIN()
        XCTAssertTrue(backend.setInitialPINCalls.isEmpty,
                      "a typo here would produce a key whose PIN nobody knows")
    }

    func testATooShortPinNeverReachesTheKey() async {
        let (store, backend, _) = await freshKeyStore()
        store.pinForm.new = "123"
        store.pinForm.confirm = "123"

        XCTAssertNotNil(store.pinFormIssue(forChange: false))
        await store.setInitialPIN()
        XCTAssertTrue(backend.setInitialPINCalls.isEmpty)
    }

    // MARK: - Change

    func testChangingThePinAdoptsTheNewOne() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        store.pinForm.current = "1234"
        store.pinForm.new = "567890"
        store.pinForm.confirm = "567890"

        await store.changePIN()

        XCTAssertEqual(backend.changePINCalls.count, 1)
        XCTAssertEqual(backend.pins[device.path], "567890")
        XCTAssertEqual(store.devices.pin(for: device.path), "567890",
                       "the vault must hold the PIN that now opens the key, not the one that does not")
        XCTAssertTrue(store.isSelectedKeyUnlocked)
        XCTAssertEqual(store.pinForm, HUDStore.PinForm())
    }

    /// A typo in this form must not cost access that the old PIN still grants.
    func testAWrongCurrentPinLeavesTheVaultAlone() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        store.pinForm.current = "9999"
        store.pinForm.new = "567890"
        store.pinForm.confirm = "567890"

        await store.changePIN()

        XCTAssertEqual(backend.pins[device.path], "1234", "the key's PIN is unchanged")
        XCTAssertEqual(store.devices.pin(for: device.path), "1234")
        XCTAssertTrue(store.isSelectedKeyUnlocked, "the old PIN still works, so access is not lost")
        XCTAssertNotNil(store.errorText)
        XCTAssertEqual(store.pinForm.new, "567890", "retyping a new PIN that was fine is busywork")
    }

    /// The point of validating locally: an attempt spent on a new PIN that was never going to
    /// be accepted is an attempt spent for nothing, and there are only eight.
    func testAnInvalidNewPinCostsNoAttempt() async {
        let (store, backend, _) = await HUDTestFactory.unlockedStore()
        store.pinForm.current = "1234"
        store.pinForm.new = "12"
        store.pinForm.confirm = "12"

        await store.changePIN()

        XCTAssertTrue(backend.changePINCalls.isEmpty)
    }

    func testChangingToTheSamePinIsRefusedBeforeTheKeySeesIt() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        store.pinForm.current = "123456"
        store.pinForm.new = "123456"
        store.pinForm.confirm = "123456"

        XCTAssertEqual(store.pinFormIssue(forChange: true), PinPolicy.Issue.sameAsOld.message)
        XCTAssertFalse(store.canSubmitPinForm(forChange: true))
    }

    /// A key demanding a PIN change refuses everything else, and a silent refusal cannot be
    /// explained to anyone.
    func testAKeyDemandingAChangeGetsThatScreen() async {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.statusByPath[device.path] = DeviceStatus(pinRetriesRemaining: 8,
                                                         hasPIN: true,
                                                         supportsHmacSecret: true,
                                                         remainingResidentKeys: 20,
                                                         forcePINChange: true)
        let store = HUDTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()

        // Changing the PIN lives in the manager window now, so the panel's job is to say so
        // and offer the way there.
        XCTAssertEqual(store.effectiveRoute, .pinChangeRequired)
        // Not a screen the user can navigate away from: the key would refuse whatever they
        // navigated to, and an unexplained refusal is worse than a screen they did not ask for.
        store.backToAccounts()
        XCTAssertEqual(store.effectiveRoute, .pinChangeRequired)
    }

    // MARK: - Reset

    private func armedResetStore() async -> (HUDStore, MockKeyBackend, FidoDevice) {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        HUDTestFactory.seedLabels(store, ["work"])
        await store.beginReset()
        store.resetFlow?.acknowledged = true
        store.resetFlow?.typed = "RESET"
        store.armReset()
        return (store, backend, device)
    }

    /// After the reconnect the path is different and a vendor signature only names a model.
    /// With two keys present there is no way left to tell which one came back.
    func testResetRefusesToStartWithTwoKeysConnected() async {
        let (store, backend, _) = await HUDTestFactory.unlockedStore()
        backend.devices.append(MockKeyBackend.device(path: "/dev/two"))
        await store.devices.refresh()

        await store.beginReset()

        XCTAssertNil(store.resetFlow)
        XCTAssertNotNil(store.errorText)
    }

    /// A local account cannot be recovered by any means, so a checkbox is not enough.
    func testAKeyHoldingALocalAccountAsksForTheWordToBeTyped() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        await store.beginReset()
        store.resetFlow?.acknowledged = true

        XCTAssertEqual(store.resetFlow?.requiresTypedConfirmation, true)
        XCTAssertEqual(store.resetFlow?.canProceed, false)
        store.resetFlow?.typed = "RESET"
        XCTAssertEqual(store.resetFlow?.canProceed, true)
    }

    func testTheKeyComingBackRunsTheResetAndLandsInBootstrap() async {
        let (store, backend, device) = await armedResetStore()

        backend.devices = []
        await store.devices.refresh()
        XCTAssertEqual(store.resetFlow?.stage, .replug)

        backend.devices = [device]
        await store.devices.refresh()
        await store.resetTask?.value

        XCTAssertEqual(backend.resetCalls, [device.path])
        XCTAssertNil(store.resetFlow)
        XCTAssertEqual(store.devices.state(for: device.path)?.hasPIN, false)
        XCTAssertEqual(store.effectiveRoute, .setPIN,
                       "a key with no PIN is unusable, and an empty account list would be the old dead end")
    }

    /// The credential ids these histories are keyed by will never exist again.
    func testResetForgetsWhatCanNeverBeAskedForAgain() async {
        let (store, backend, device) = await armedResetStore()
        XCTAssertFalse(store.labels.histories.isEmpty)

        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()
        await store.resetTask?.value

        XCTAssertTrue(store.labels.histories.isEmpty)
        XCTAssertNil(store.preferences.lastUsed)
        XCTAssertTrue(store.accounts.accounts.isEmpty)
    }

    /// A matching AAGUID proves nothing, but a differing one proves the key is not the same —
    /// and erasing the wrong key is not a recoverable mistake.
    func testADifferentKeyComingBackIsNotErased() async {
        let (store, backend, device) = await armedResetStore()

        backend.devices = []
        await store.devices.refresh()
        backend.aaguid = "ff" + String(repeating: "00", count: 15)
        backend.devices = [device]
        await store.devices.refresh()
        await store.resetTask?.value

        XCTAssertNotNil(store.errorText)
        XCTAssertEqual(store.resetFlow?.stage, .replug, "the flow waits rather than pretending it worked")
        XCTAssertEqual(backend.pins[device.path], "1234", "the key still has its PIN, so nothing was erased")
        XCTAssertFalse(backend.accountsByPath[device.path, default: []].isEmpty)
    }

    /// Fetching a backup key is the one legitimate detour out of this wizard — it is the last
    /// moment that value can be had. Coming back must return to the wizard rather than drop
    /// the user on the account list with a reset still armed behind it.
    ///
    /// The wizard is a sheet in the manager window now, so the panel is free to go wherever
    /// the user sends it — what must not happen is the flow quietly disappearing while it is
    /// still armed.
    func testFetchingABackupKeyDoesNotAbandonAnArmedReset() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        await store.beginReset()
        guard let portable = store.resetFlow?.doomed.first(where: { $0.kind == .portable }) else {
            return XCTFail("the fixture is supposed to have a portable account")
        }

        await store.showBackupKey(for: portable.ref)
        XCTAssertEqual(store.route, .backupKey(portable.ref))

        store.backToAccounts()
        XCTAssertEqual(store.route, .accounts)
        XCTAssertNotNil(store.resetFlow, "the wizard is in another window and outlives this one")
    }

    /// A user who unplugged the key and then thought better of it must not be held in the
    /// wizard. Only the erase itself is past the point of cancelling.
    func testTheWizardCanBeCancelledUntilTheKeyIsBeingErased() async {
        let (store, backend, device) = await armedResetStore()

        backend.devices = []
        await store.devices.refresh()
        XCTAssertEqual(store.resetFlow?.stage, .replug)

        store.cancelReset()
        XCTAssertNil(store.resetFlow)
        XCTAssertNil(store.devices.armedReset)

        backend.devices = [device]
        await store.devices.refresh()
        await store.resetTask?.value
        XCTAssertTrue(backend.resetCalls.isEmpty, "a cancelled wizard must not still fire")
    }

    /// The acknowledgement is waived only for a key that is *known* to hold nothing. A locked
    /// key enumerates to an empty list precisely because its contents are unknown, and waiving
    /// the warning there would skip it in the one case where the user knows least about what
    /// they are erasing. It used to be waived on any empty list, which also left the checkbox
    /// on screen doing nothing.
    func testAcknowledgementIsOnlyWaivedForAKeyKnownToBeEmpty() {
        var unreadable = HUDStore.ResetFlow(deviceName: "Key", expectedAAGUID: nil,
                                            doomed: [], accountsReadable: false, scopes: [])
        XCTAssertFalse(unreadable.isKnownEmpty)
        XCTAssertFalse(unreadable.canProceed, "an unreadable key still needs the warning read")
        unreadable.acknowledged = true
        XCTAssertTrue(unreadable.canProceed)

        let empty = HUDStore.ResetFlow(deviceName: "Key", expectedAAGUID: nil,
                                       doomed: [], accountsReadable: true, scopes: [])
        XCTAssertTrue(empty.isKnownEmpty)
        XCTAssertTrue(empty.canProceed, "nothing to acknowledge — and no checkbox is shown")
    }

    /// The wizard tells the user to unplug the key. When they do, the flow must survive the
    /// key being gone — that absence is the step, not a failure.
    func testTheWizardSurvivesTheKeyBeingOut() async {
        let (store, backend, _) = await armedResetStore()

        backend.devices = []
        await store.devices.refresh()

        XCTAssertNotNil(store.resetFlow)
        XCTAssertEqual(store.resetFlow?.stage, .replug)
    }

    /// The bootstrap screen appears on its own, just by plugging in a new key. It may not
    /// make the panel unclosable before the user has typed anything into it.
    func testTheBootstrapScreenOnlyPinsThePanelOnceItHasTyping() async {
        let (store, _, _) = await freshKeyStore()
        XCTAssertEqual(store.effectiveRoute, .setPIN)
        XCTAssertFalse(store.isPinnedOpen)

        store.pinForm.new = "12"
        XCTAssertTrue(store.isPinnedOpen, "half a PIN is something the user cannot get back")
    }

    /// Closing the panel must **not** disarm the reset any more: the wizard lives in the
    /// manager window, and that window taking focus is what closes the panel. Disarming there
    /// would cancel the flow at the exact moment the user went to drive it.
    func testClosingThePanelLeavesTheResetArmed() async {
        let (store, backend, device) = await armedResetStore()

        store.panelDidClose()

        XCTAssertNotNil(store.resetFlow)
        XCTAssertNotNil(store.devices.armedReset)

        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()
        await store.resetTask?.value

        XCTAssertEqual(backend.resetCalls, [device.path], "the flow the user armed still runs")
    }

    /// The arming still has to expire on its own, or a reset nobody is watching would fire on
    /// whatever key is plugged in next. That timeout lives in `DeviceStore.armReset`.
    func testCancellingDisarmsTheReset() async {
        let (store, backend, device) = await armedResetStore()

        store.cancelReset()
        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()
        await store.resetTask?.value

        XCTAssertTrue(backend.resetCalls.isEmpty)
        XCTAssertNil(store.devices.armedReset)
    }
}
