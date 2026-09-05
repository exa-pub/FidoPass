#if FIDOPASS_VIRTUAL_KEYS
import XCTest
import FidoPassCore
import FidoPassVirtualKeys
import TestSupport
@testable import FidoPassAppKit

@MainActor
final class VirtualAppKeyTransportIntegrationTests: AppTestCase {
    private func setup(presence: OpenSKHostClient.Presence = .immediate) throws -> (VirtualDeviceRegistry, AppContainer, VirtualDeviceStore) {
        let executable = OpenSKHostClient.executable
        if !FileManager.default.isExecutableFile(atPath: executable.path),
           ProcessInfo.processInfo.environment["FIDOPASS_REQUIRE_KEY_TESTS"] != "1" {
            throw XCTSkip("Run scripts/test_keys.sh")
        }
        let registry = VirtualDeviceRegistry(executable: executable, presence: presence,
                                             realtime: false, touchTimeoutMilliseconds: 5_000)
        let container = AppTestFactory.makeContainer(backend: LiveKeyBackend(core: registry.core))
        return (registry, container, VirtualDeviceStore(registry: registry, devices: container.devices, executable: executable))
    }

    func testAddingConnectingAndRemovingUsePresenceWithoutReadingTheKey() async throws {
        let (registry, container, controls) = try setup()
        defer { registry.stop() }
        await controls.add(profile: .standard)
        let row = try XCTUnwrap(controls.devices.first)
        let path = try XCTUnwrap(row.device?.path)
        XCTAssertEqual(container.devices.devices.count, 1)
        XCTAssertNil(container.devices.state(for: path)?.hasPIN)
        XCTAssertTrue(container.accounts.accounts.isEmpty)
        XCTAssertNil(controls.error)
        await controls.toggleConnection(row)
        XCTAssertTrue(container.devices.devices.isEmpty)
        let disconnected = try XCTUnwrap(controls.devices.first)
        await controls.toggleConnection(disconnected)
        let reconnected = try XCTUnwrap(controls.devices.first)
        XCTAssertNotEqual(reconnected.device?.path, path)
        XCTAssertNil(container.devices.states.values.first?.hasPIN)
        await controls.remove(reconnected)
        XCTAssertTrue(controls.devices.isEmpty)
        XCTAssertTrue(container.devices.devices.isEmpty)
    }

    func testDisconnectDuringGenerationRevokesSessionAndClosesDecryptor() async throws {
        let (registry, container, controls) = try setup()
        defer { registry.stop() }
        await controls.add(profile: .standard)
        let row = try XCTUnwrap(controls.devices.first)
        let path = try XCTUnwrap(row.device?.path)
        let core = registry.core
        try await Task.detached {
            try core.setInitialPIN(devicePath: path, newPIN: "1234")
            _ = try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" })
        }.value
        let panel = container.panel
        await panel.prepareForDisplay()
        panel.pinDraft = "1234"
        await panel.submitPin()
        XCTAssertTrue(panel.isSelectedKeyUnlocked)
        panel.openDecryptor()
        XCTAssertNotNil(container.decryptor.store)
        let lease = container.devices.lease(for: path)
        let host = try registry.host(id: row.id)
        try host.configurePresence(.controlled)
        let generation = Task { await panel.copyPassword(for: panel.selection, label: "master") }
        let reached = await Task.detached { host.waitForTouch() }.value
        XCTAssertTrue(reached)
        await controls.toggleConnection(row)
        await generation.value
        XCTAssertFalse(lease.isValid)
        XCTAssertNil(container.devices.pin(for: path))
        XCTAssertNil(container.decryptor.store)
        XCTAssertTrue(container.accounts.accounts.isEmpty)
        XCTAssertNil(container.generation.result)
        XCTAssertFalse(container.touchGate.isWorking)
        await controls.toggleConnection(try XCTUnwrap(controls.devices.first))
        XCTAssertFalse(panel.isSelectedKeyUnlocked)
        panel.pinDraft = "1234"
        await panel.submitPin()
        XCTAssertEqual(container.accounts.accounts.count, 1)
    }

    func testManagerResetRunsAfterReconnectAndUsesTheVirtualTouchButton() async throws {
        let (registry, container, controls) = try setup(presence: .controlled)
        defer { registry.stop() }
        await controls.add(profile: .standard)
        let row = try XCTUnwrap(controls.devices.first)
        let device = try XCTUnwrap(row.device)
        let core = registry.core
        try await Task.detached { try core.setInitialPIN(devicePath: device.path, newPIN: "1234") }.value
        try await container.reset.begin(device: device)
        container.reset.flow?.acknowledged = true
        container.reset.arm()
        XCTAssertEqual(container.reset.flow?.stage, .unplug)
        await controls.toggleConnection(row)
        XCTAssertEqual(container.reset.flow?.stage, .replug)
        await controls.toggleConnection(try XCTUnwrap(controls.devices.first))
        try await waitUntil { controls.devices.first?.touch != nil }
        XCTAssertEqual(container.touchGate.surface, .manager)
        await controls.touch(try XCTUnwrap(controls.devices.first))
        await container.reset.task?.value
        XCTAssertNil(container.reset.error)
        XCTAssertNil(container.reset.flow)
        XCTAssertFalse(container.devices.states.values.first?.hasPIN ?? true)
    }

    func testMissingBundledHelperShowsAnErrorWithoutDevices() async {
        let executable = URL(fileURLWithPath: "/missing/helper")
        let registry = VirtualDeviceRegistry(executable: executable)
        defer { registry.stop() }
        let container = AppTestFactory.makeContainer(backend: LiveKeyBackend(core: registry.core))
        let controls = VirtualDeviceStore(registry: registry, devices: container.devices, executable: executable)
        XCTAssertFalse(controls.helperAvailable)
        XCTAssertNotNil(controls.error)
        await controls.add(profile: .standard)
        await container.devices.refresh()
        XCTAssertTrue(container.devices.devices.isEmpty)
    }
}
#endif
