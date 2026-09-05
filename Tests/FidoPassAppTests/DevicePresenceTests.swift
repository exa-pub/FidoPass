import XCTest
import FidoPassCore
@testable import FidoPassAppKit

@MainActor
final class DevicePresenceTests: AppTestCase {
    func testAnOldEnumerationCannotRestoreADeviceAfterPresenceChanged() async throws {
        let old = MockKeyBackend.device(path: "mock://old")
        let next = MockKeyBackend.device(path: "mock://next")
        let backend = DelayedListingBackend()
        backend.devices = [old]
        defer { backend.gate.open() }
        let container = AppTestFactory.makeContainer(backend: backend)
        container.devices.replaceConnectedDevices([old])
        let lease = container.devices.lease(for: old.path)
        let refresh = Task { await container.devices.refresh() }
        try await waitUntil { backend.gate.hasEntered }
        container.devices.replaceConnectedDevices([next])
        XCTAssertFalse(lease.isValid)
        backend.gate.open()
        await refresh.value
        XCTAssertEqual(container.devices.devices, [next])
        XCTAssertNil(container.devices.state(for: old.path))
    }
}

/// The immutable listing is captured before the gate; only the worker calls this override.
private final class DelayedListingBackend: MockKeyBackend, @unchecked Sendable {
    let gate = BlockingGate()
    override func listDevices() throws -> [FidoDevice] {
        let listed = devices
        gate.wait()
        return listed
    }
}
