import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// A security key is exclusive: opening it seizes the device, so two operations that overlap
/// mean one fails for a reason unrelated to anything the user did.
///
/// This could not happen while the panel was the only caller — a panel does one thing at a
/// time. The manager window changed that: it can read a key while the panel is generating a
/// password from the same one. `KeyWorker` therefore funnels every call through a single
/// serial queue, and this is the test that says so.
@MainActor
final class KeyAccessSerialisationTests: AppTestCase {

    /// Counts how many calls are inside the backend at once. Anything above one is the defect.
    private final class OverlapCountingBackend: MockKeyBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private(set) var maxConcurrent = 0

        override func inspect(devicePath: String) throws -> AuthenticatorInfo {
            enter()
            defer { leave() }
            Thread.sleep(forTimeInterval: 0.02)
            return try super.inspect(devicePath: devicePath)
        }

        override func listDevices() throws -> [FidoDevice] {
            enter()
            defer { leave() }
            Thread.sleep(forTimeInterval: 0.02)
            return try super.listDevices()
        }

        override func generatePassword(_ handle: AccountHandle, label: String, pinProvider: @escaping @Sendable () -> String?) throws -> String {
            enter()
            defer { leave() }
            Thread.sleep(forTimeInterval: 0.02)
            return try super.generatePassword(handle, label: label, pinProvider: pinProvider)
        }

        override func deriveMessageKey(_ handle: AccountHandle, nonce: Data, pinProvider: @escaping @Sendable () -> String?) throws -> MessageKey {
            enter()
            defer { leave() }
            Thread.sleep(forTimeInterval: 0.02)
            return try super.deriveMessageKey(handle, nonce: nonce, pinProvider: pinProvider)
        }

        private func enter() {
            lock.lock()
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
            lock.unlock()
        }

        private func leave() {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
    }

    func testOverlappingOperationsAreSerialised() async {
        let backend = OverlapCountingBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        let store = AppTestFactory.makeStore(backend: backend)
        await store.devices.refresh()

        // The manager reading while the panel refreshes: two windows, one key.
        async let read: Void = store.inventory.read(device)
        async let refreshOne: Void = store.devices.refresh()
        async let refreshTwo: Void = store.devices.refresh()
        _ = await (read, refreshOne, refreshTwo)

        XCTAssertEqual(backend.maxConcurrent, 1,
                       "two operations reached the key at once; one of them would have failed on real hardware")
    }

    /// The receiving window derives a key while the panel generates a password from the same
    /// authenticator — three windows now, still one queue.
    func testTheReceivingWindowSharesTheQueueWithThePanel() async throws {
        let backend = OverlapCountingBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.accountsByPath[device.path] = [Account.fixture(id: "disk", kind: .local)]
        let store = AppTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()
        store.pinDraft = "1234"
        await store.submitPin()
        let disk = try XCTUnwrap(store.accounts.account(AccountRef(accountId: "disk", devicePath: device.path)))

        async let key = store.accounts.deriveMessageKey(for: disk, nonce: MockKeyBackend.testNonce)
        async let password = store.generation.generate(disk, label: "a")
        async let read: Void = store.inventory.read(device)
        _ = try await (key, password, read)

        XCTAssertEqual(backend.maxConcurrent, 1)
    }
}
