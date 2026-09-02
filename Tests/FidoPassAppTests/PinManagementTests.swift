import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// Giving a key its first PIN — the one PIN operation the panel does itself.
///
/// What is asserted here is mostly what must *not* happen: attempts not spent, a PIN not
/// left in the form, a doubled keypress not doubled on the key. Changing the PIN and erasing
/// the key live in the manager; see `ManagerStoreTests` and `ResetCoordinatorTests`.
@MainActor
final class PinManagementTests: XCTestCase {

    /// A key straight out of its packet: present, no PIN, nothing on it.
    private func freshKeyStore() async -> (PanelStore, MockKeyBackend, FidoDevice) {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.statusByPath[device.path] = DeviceStatus(pinRetriesRemaining: nil,
                                                         hasPIN: false,
                                                         supportsHmacSecret: true,
                                                         remainingResidentKeys: 25,
                                                         aaguid: backend.aaguid)
        let store = AppTestFactory.makeStore(backend: backend)
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
        XCTAssertTrue(store.pinForm.isEmpty, "the PIN must not be left in the form")
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

        XCTAssertFalse(store.pinForm.canSubmit)
        await store.setInitialPIN()
        XCTAssertTrue(backend.setInitialPINCalls.isEmpty,
                      "a typo here would produce a key whose PIN nobody knows")
    }

    func testATooShortPinNeverReachesTheKey() async {
        let (store, backend, _) = await freshKeyStore()
        store.pinForm.new = "123"
        store.pinForm.confirm = "123"

        XCTAssertNotNil(store.pinForm.issue)
        await store.setInitialPIN()
        XCTAssertTrue(backend.setInitialPINCalls.isEmpty)
    }

    /// The key said no — it already has a PIN, say. The panel explains rather than repeating
    /// the key's bare status.
    func testARefusedFirstPinIsExplained() async {
        let (store, backend, _) = await freshKeyStore()
        backend.setInitialPINError = FidoPassError.libfido2(operation: "dev_set_pin", status: .notAllowed, message: "not allowed")
        store.pinForm.new = "246813"
        store.pinForm.confirm = "246813"

        await store.setInitialPIN()

        XCTAssertEqual(store.error?.kind, .notAllowed)
        XCTAssertEqual(store.error?.fullText().contains("already has a PIN"), true)
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

    // MARK: - A key demanding a change

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
        let store = AppTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()

        // Changing the PIN lives in the manager window, so the panel's job is to say so
        // and offer the way there.
        XCTAssertEqual(store.effectiveRoute, .pinChangeRequired)
        // Not a screen the user can navigate away from: the key would refuse whatever they
        // navigated to, and an unexplained refusal is worse than a screen they did not ask for.
        store.backToAccounts()
        XCTAssertEqual(store.effectiveRoute, .pinChangeRequired)
    }
}
