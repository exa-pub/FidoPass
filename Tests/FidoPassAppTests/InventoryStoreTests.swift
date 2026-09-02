import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// The manager's store.
///
/// Two rules dominate these tests. **Nothing is read until asked**, because opening a key on
/// macOS seizes it away from every other process — the same rule `DeviceAccessTests` enforces
/// for the panel. And **a locked key loses its credential list but keeps its self-description**,
/// because the list names other services' accounts while the self-description is public
/// information about the model.
@MainActor
final class InventoryStoreTests: XCTestCase {

    private func makeStore() -> (PanelStore, MockKeyBackend, FidoDevice) {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.inventoryByPath[device.path] = MockKeyBackend.inventory(count: 2)
        return (AppTestFactory.makeStore(backend: backend), backend, device)
    }

    // MARK: - Nothing happens by itself

    /// Building the store — which happens for every launch, manager window open or not —
    /// must not touch the key.
    func testCreatingTheStoreOpensNothing() async {
        let (store, backend, _) = makeStore()
        await store.devices.refresh()

        XCTAssertEqual(backend.inspectCallCount, 0)
        XCTAssertEqual(backend.inventoryCallCount, 0)
        XCTAssertTrue(store.inventory.readings.isEmpty)
    }

    /// A key being plugged in is not a request to read it.
    func testHotPlugDoesNotRead() async {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        backend.devices = []
        await store.devices.refresh()
        backend.devices = [device]
        await store.devices.refresh()

        XCTAssertEqual(backend.inspectCallCount, 0, "a key that merely appeared must stay free for other tools")
    }

    // MARK: - Reading

    func testReadingAnUnlockedKeyGetsBothHalves() async throws {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")

        await store.inventory.read(device)

        let reading = store.inventory.reading(for: device.path)
        XCTAssertEqual(backend.inspectCallCount, 1)
        XCTAssertEqual(backend.inventoryCallCount, 1)
        XCTAssertNotNil(reading.info)
        XCTAssertEqual(reading.inventory?.credentialCount, 2)
        XCTAssertFalse(reading.needsUnlock)
        XCTAssertFalse(reading.isReading)
    }

    /// A locked key still describes itself — that costs no PIN. What it must *not* do is
    /// invent a second place in the app that can spend a PIN attempt.
    func testReadingALockedKeyGetsTheSelfDescriptionAndAsksForUnlock() async {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()

        await store.inventory.read(device)

        let reading = store.inventory.reading(for: device.path)
        XCTAssertNotNil(reading.info, "the self-description needs no PIN")
        XCTAssertNil(reading.inventory)
        XCTAssertTrue(reading.needsUnlock)
        XCTAssertNil(reading.inventoryError, "a locked key is not a failure")
        XCTAssertEqual(backend.inventoryCallCount, 0, "no PIN, so nothing may be attempted")
    }

    /// "This key cannot be asked" must not look like "this key holds nothing".
    func testAKeyWithoutCredentialManagementReportsAnError() async throws {
        let (store, backend, device) = makeStore()
        backend.inventoryError = FidoPassError.unsupported("This key does not support credential management")
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")

        await store.inventory.read(device)

        let reading = store.inventory.reading(for: device.path)
        XCTAssertNil(reading.inventory)
        XCTAssertNotNil(reading.inventoryError)
        XCTAssertFalse(reading.needsUnlock, "it is not locked — it cannot do this at all")
    }

    /// A key that holds nothing is a legitimate answer, and must read as an empty list
    /// rather than as a failure.
    func testAnEmptyKeyIsAnEmptyInventoryNotAnError() async throws {
        let (store, backend, device) = makeStore()
        backend.inventoryByPath[device.path] = CredentialInventory(relyingParties: [],
                                                                   residentKeysUsed: 0,
                                                                   residentKeysRemaining: 100,
                                                                   largeBlobArrayBytes: nil)
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")
        await store.inventory.read(device)

        let reading = store.inventory.reading(for: device.path)
        XCTAssertEqual(reading.inventory?.credentialCount, 0)
        XCTAssertNil(reading.inventoryError)
    }

    /// Re-reading after an unlock keeps the self-description already on screen instead of
    /// paying for a second open of the key.
    func testReadInventoryAloneDoesNotReInspect() async throws {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        await store.inventory.read(device)
        try await store.devices.unlock(device, pin: "1234")

        await store.inventory.readInventory(device)

        XCTAssertEqual(backend.inspectCallCount, 1, "the self-description was already read")
        XCTAssertEqual(backend.inventoryCallCount, 1)
        XCTAssertEqual(store.inventory.reading(for: device.path).inventory?.credentialCount, 2)
    }

    /// The reported bug: the key was unlocked and the manager still showed nothing. Reading
    /// while locked leaves the request half-done, and unlocking must finish it rather than
    /// wait for the user to guess that another button press is needed.
    func testUnlockingFinishesAReadThatWasWaitingForIt() async throws {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        await store.inventory.read(device)
        XCTAssertTrue(store.inventory.reading(for: device.path).needsUnlock)

        try await store.devices.unlock(device, pin: "1234")
        await store.inventory.resumeAfterUnlock(device)

        let reading = store.inventory.reading(for: device.path)
        XCTAssertEqual(reading.inventory?.credentialCount, 2)
        XCTAssertFalse(reading.needsUnlock)
        XCTAssertEqual(backend.inspectCallCount, 1, "the self-description was not re-fetched")
    }

    /// But an unlock is not itself a request to read. A key nobody has asked about stays
    /// untouched, however many times it is unlocked for the panel's own purposes.
    func testUnlockingAKeyNobodyAskedAboutReadsNothing() async throws {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")

        await store.inventory.resumeAfterUnlock(device)

        XCTAssertEqual(backend.inspectCallCount, 0)
        XCTAssertEqual(backend.inventoryCallCount, 0, "unlocking verifies the PIN by enumerating accounts, not by reading the inventory")
        XCTAssertTrue(store.inventory.readings.isEmpty)
    }

    /// After a setting is changed the self-description has to be re-read, because `alwaysUv`
    /// is a toggle and the app's guess at the resulting state can be backwards.
    func testRefreshInfoRereadsOnlyTheSelfDescription() async throws {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")
        await store.inventory.read(device)

        await store.inventory.refreshInfo(device)

        XCTAssertEqual(backend.inspectCallCount, 2)
        XCTAssertEqual(backend.inventoryCallCount, 1, "the credential list was not re-fetched")
        XCTAssertEqual(store.inventory.reading(for: device.path).inventory?.credentialCount, 2)
    }

    /// A read that was attempted on an open key and failed must say why. It used to keep the
    /// "needs unlock" flag set, and the sidebar showed "locked" — sending the user to re-enter
    /// a PIN that was never the problem, while the real reason stayed invisible.
    func testAFailureOnAnUnlockedKeyIsAFailureNotALock() async throws {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        await store.inventory.read(device)
        XCTAssertTrue(store.inventory.reading(for: device.path).needsUnlock)

        backend.inventoryError = FidoPassError.unsupported("This key does not support credential management")
        try await store.devices.unlock(device, pin: "1234")
        await store.inventory.resumeAfterUnlock(device)

        let reading = store.inventory.reading(for: device.path)
        XCTAssertFalse(reading.needsUnlock, "the key is open — this is not a lock")
        XCTAssertNotNil(reading.inventoryError)
        XCTAssertEqual(reading.inventoryError?.kind, .unsupported)
        XCTAssertTrue(reading.inventoryError?.fullText().contains("credential management") == true,
                      "the reason must survive, not just the headline")
    }

    // MARK: - Forgetting

    /// Locking the key puts away the list of other services' accounts, and keeps the public
    /// facts about the model.
    func testLockingDropsTheCredentialListButKeepsTheSelfDescription() async throws {
        let (store, _, device) = makeStore()
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")
        await store.inventory.read(device)
        XCTAssertNotNil(store.inventory.reading(for: device.path).inventory)

        store.devices.lock(path: device.path)

        let reading = store.inventory.reading(for: device.path)
        XCTAssertNil(reading.inventory, "the credential list names other people's accounts")
        XCTAssertNotNil(reading.info, "what the key says about itself is public")
        XCTAssertTrue(reading.needsUnlock)
    }

    /// An unplugged key leaves nothing behind: there is no key to describe any more.
    func testUnpluggingForgetsTheKeyEntirely() async throws {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")
        await store.inventory.read(device)

        backend.devices = []
        await store.devices.refresh()

        XCTAssertNil(store.inventory.readings[device.path])
    }

    func testSessionLockForgetsEverything() async throws {
        let (store, _, device) = makeStore()
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")
        await store.inventory.read(device)

        store.devices.lockAll()
        store.inventory.dropAll()

        XCTAssertTrue(store.inventory.readings.isEmpty)
    }

    /// Two keys must not share a reading: showing one key's credentials under the other's
    /// name would be worse than showing none.
    func testReadingsAreKeptPerDevice() async throws {
        let backend = MockKeyBackend()
        let first = MockKeyBackend.device(path: "/dev/one")
        let second = MockKeyBackend.device(path: "/dev/two", product: "Security Key")
        backend.devices = [first, second]
        backend.pins[first.path] = "1111"
        backend.pins[second.path] = "2222"
        backend.inventoryByPath[first.path] = MockKeyBackend.inventory(rpId: "one.test", count: 1)
        backend.inventoryByPath[second.path] = MockKeyBackend.inventory(rpId: "two.test", count: 3)

        let store = AppTestFactory.makeStore(backend: backend)
        await store.devices.refresh()
        try await store.devices.unlock(first, pin: "1111")
        try await store.devices.unlock(second, pin: "2222")

        await store.inventory.read(first)
        await store.inventory.read(second)

        XCTAssertEqual(store.inventory.reading(for: first.path).inventory?.relyingParties.first?.id, "one.test")
        XCTAssertEqual(store.inventory.reading(for: second.path).inventory?.credentialCount, 3)
    }
}
