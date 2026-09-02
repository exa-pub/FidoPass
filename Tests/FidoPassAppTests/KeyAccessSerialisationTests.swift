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
final class KeyAccessSerialisationTests: XCTestCase {

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
}
