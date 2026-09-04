import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// When the app is allowed to open a security key.
///
/// Opening a key is not a read — on macOS libfido2 opens it with
/// `kIOHIDOptionsTypeSeizeDevice`, which locks every other process out for the duration.
/// A running FidoPass therefore used to make `ykman fido reset` impossible: the key was
/// seized within a second of being plugged in, because the PIN screen appeared and asked it
/// how many attempts were left. Nobody had asked for that.
///
/// The rule these tests pin: **a key is opened because the user asked, never because it
/// appeared.** The assertions count calls rather than inspect values — the number of times
/// the key was taken over is the whole subject.
@MainActor
final class DeviceAccessTests: AppTestCase {

    private func backendWithOneKey() -> (MockKeyBackend, FidoDevice) {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        return (backend, device)
    }

    /// The hot-plug path. `DeviceStore.refresh` is what a monitor event runs, and it must get
    /// no further than `listDevices` — which enumerates HID properties without opening
    /// anything.
    func testAKeyAppearingIsNeverOpened() async {
        let (backend, _) = backendWithOneKey()
        let store = AppTestFactory.makeStore(backend: backend)

        await store.devices.refresh()

        XCTAssertEqual(backend.statusCallCount, 0,
                       "a key that was merely plugged in must stay free for other tools")
        XCTAssertGreaterThan(backend.listDevicesCallCount, 0, "it should still be listed")
    }

    /// Plug, unplug, plug again — a realistic monitor storm, and still nothing opens the key.
    func testRepeatedMonitorEventsNeverOpenTheKey() async {
        let (backend, device) = backendWithOneKey()
        let store = AppTestFactory.makeStore(backend: backend)

        await store.devices.refresh()
        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()

        XCTAssertEqual(backend.statusCallCount, 0)
    }

    /// Opening the panel *is* a request: the screen about to be shown depends on whether the
    /// key has a PIN, and the attempts left have to be visible before one is spent.
    func testOpeningThePanelReadsTheStatusOnce() async {
        let (backend, _) = backendWithOneKey()
        let store = AppTestFactory.makeStore(backend: backend)

        await store.prepareForDisplay()

        XCTAssertEqual(backend.statusCallCount, 1)
    }

    /// An unlocked key demonstrably has a PIN and its state is already known, so opening the
    /// panel on one buys nothing and costs a seizure.
    func testOpeningThePanelOnAnUnlockedKeyReadsNothing() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        let before = backend.statusCallCount

        await store.prepareForDisplay()

        XCTAssertEqual(backend.statusCallCount, before)
    }

    /// The state the status read exists to establish still arrives — this is not a test that
    /// the feature was deleted.
    func testTheStatusReadStillReachesTheKeyState() async {
        let (backend, device) = backendWithOneKey()
        backend.statusByPath[device.path] = DeviceStatus(pinRetriesRemaining: 3,
                                                         hasPIN: true,
                                                         supportsHmacSecret: true,
                                                         remainingResidentKeys: 20)
        let store = AppTestFactory.makeStore(backend: backend)

        await store.prepareForDisplay()

        XCTAssertEqual(store.devices.state(for: device.path)?.pinRetriesRemaining, 3)
        XCTAssertEqual(store.devices.state(for: device.path)?.hasPIN, true)
    }

    /// A key that appears while the panel is already open has never been asked. Typing a PIN
    /// is asking: the first character reads the attempts left, later ones do not.
    func testTypingAPinReadsTheStatusOfAKeyNobodyAskedYet() async {
        let (backend, _) = backendWithOneKey()
        let store = AppTestFactory.makeStore(backend: backend)
        await store.devices.refresh()   // the hot-plug path: listed, never opened
        XCTAssertEqual(backend.statusCallCount, 0)

        store.pinDraft = "1"
        await store.pinDraftDidChange()
        XCTAssertEqual(backend.statusCallCount, 1)

        store.pinDraft = "12"
        await store.pinDraftDidChange()
        XCTAssertEqual(backend.statusCallCount, 1, "one read per PIN being typed")
    }

    /// Once the panel has opened normally the key's state is known, and typing must not open
    /// it a second time for the same answer.
    func testTypingAPinAfterThePanelOpenedReadsNothingMore() async {
        let (backend, _) = backendWithOneKey()
        let store = AppTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()
        XCTAssertEqual(backend.statusCallCount, 1)

        store.pinDraft = "1"
        await store.pinDraftDidChange()
        XCTAssertEqual(backend.statusCallCount, 1)
    }
}
