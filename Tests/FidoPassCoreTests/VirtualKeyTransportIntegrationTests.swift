import XCTest
import Foundation
import FidoPassCore
import FidoPassVirtualKeys
import TestSupport

@MainActor
final class VirtualKeyTransportIntegrationTests: XCTestCase {
    private func registry(presence: OpenSKHostClient.Presence = .immediate,
                          timeout: UInt32 = 5_000) throws -> VirtualDeviceRegistry {
        if !FileManager.default.isExecutableFile(atPath: OpenSKHostClient.executable.path),
           ProcessInfo.processInfo.environment["FIDOPASS_REQUIRE_KEY_TESTS"] != "1" {
            throw XCTSkip("Run scripts/test_keys.sh")
        }
        return VirtualDeviceRegistry(executable: OpenSKHostClient.executable, presence: presence,
                                     realtime: false, touchTimeoutMilliseconds: timeout)
    }

    private func path(_ registry: VirtualDeviceRegistry, _ id: UUID) throws -> String {
        try XCTUnwrap(registry.snapshot.devices.first { $0.id == id }?.device?.path)
    }

    func testDisconnectPreservesCredentialsAndPasswordWhileChangingPath() throws {
        let registry = try registry()
        defer { registry.stop() }
        let id = try registry.add()
        let core = registry.core
        let oldPath = try path(registry, id)
        try core.setInitialPIN(devicePath: oldPath, newPIN: "1234")
        let account = try core.enroll(accountId: "vault", identity: .random(), devicePath: oldPath, askPIN: { "1234" })
        let password = try core.generatePassword(account, label: "master", pinProvider: { "1234" })
        try registry.disconnect(id: id)
        XCTAssertTrue(try core.listDevices().isEmpty)
        XCTAssertEqual(registry.snapshot.devices.count, 1)
        XCTAssertThrowsError(try core.status(devicePath: oldPath))
        try registry.attach(id: id)
        let newPath = try path(registry, id)
        XCTAssertNotEqual(oldPath, newPath)
        let restored = try XCTUnwrap(core.enumerateAccounts(devicePath: newPath, pin: "1234").first)
        XCTAssertEqual(restored.account.credentialIdB64, account.account.credentialIdB64)
        XCTAssertTrue(try core.generatePassword(restored, label: "master", pinProvider: { "1234" }).utf8.elementsEqual(password.utf8))
    }

    func testDevicesHaveIndependentPINsAndRemovingOneLeavesTheOtherUsable() throws {
        let registry = try registry()
        defer { registry.stop() }
        let first = try registry.add()
        let second = try registry.add(profile: .twoSlots)
        let core = registry.core
        try core.setInitialPIN(devicePath: path(registry, first), newPIN: "1234")
        let secondPath = try path(registry, second)
        XCTAssertFalse(try core.status(devicePath: secondPath).hasPIN)
        try core.setInitialPIN(devicePath: secondPath, newPIN: "5678")
        _ = try core.enroll(accountId: "other", identity: .random(), devicePath: secondPath, askPIN: { "5678" })
        try registry.remove(id: first)
        XCTAssertEqual(registry.snapshot.devices.map(\.id), [second])
        XCTAssertEqual(try core.enumerateAccounts(devicePath: secondPath, pin: "5678").count, 1)
        let third = try registry.add()
        XCTAssertEqual(registry.snapshot.devices.map(\.name), ["OpenSK 2", "OpenSK 3"])
        XCTAssertNotEqual(first, third)
    }

    func testDisconnectWhileWaitingCancelsTheOpenWithoutDestroyingStorage() async throws {
        let registry = try registry()
        defer { registry.stop() }
        let id = try registry.add()
        let core = registry.core
        let originalPath = try path(registry, id)
        try core.setInitialPIN(devicePath: originalPath, newPIN: "1234")
        let account = try core.enroll(accountId: "vault", identity: .random(), devicePath: originalPath, askPIN: { "1234" })
        let host = try registry.host(id: id)
        try host.configurePresence(.controlled)
        let task = Task.detached { Result { try core.generatePassword(account, label: "master", pinProvider: { "1234" }) } }
        let reached = await Task.detached { host.waitForTouch() }.value
        XCTAssertTrue(reached)
        let start = ContinuousClock.now
        try await Task.detached { try registry.disconnect(id: id) }.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        if case .success = await task.value { XCTFail("Disconnected operation returned a password") }
        XCTAssertNil(host.state.failure)
        try registry.attach(id: id)
        let restored = try core.enumerateAccounts(devicePath: path(registry, id), pin: "1234")
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.account.credentialIdB64, account.account.credentialIdB64)
    }

    func testRemoveWhileWaitingReapsTheHostAndRemovesItsPath() async throws {
        let registry = try registry(presence: .controlled)
        defer { registry.stop() }
        let id = try registry.add()
        let host = try registry.host(id: id)
        let core = registry.core
        let devicePath = try path(registry, id)
        try core.setInitialPIN(devicePath: devicePath, newPIN: "1234")
        let task = Task.detached { Result { try core.enroll(accountId: "new", identity: .random(), devicePath: devicePath, askPIN: { "1234" }) } }
        let reached = await Task.detached { host.waitForTouch() }.value
        XCTAssertTrue(reached)
        try await Task.detached { try registry.remove(id: id) }.value
        if case .success = await task.value { XCTFail("Removed key completed enrollment") }
        XCTAssertTrue(registry.snapshot.devices.isEmpty)
        XCTAssertNotNil(host.state.failure)
    }

    func testPortableEnrollmentRequiresSeparateAddressedTouches() async throws {
        let registry = try registry(presence: .controlled)
        defer { registry.stop() }
        let id = try registry.add()
        let other = try registry.add()
        let host = try registry.host(id: id)
        let core = registry.core
        let devicePath = try path(registry, id)
        try core.setInitialPIN(devicePath: devicePath, newPIN: "1234")
        let task = Task.detached { try core.enrollPortable(accountId: "vault", identity: .random(), devicePath: devicePath, askPIN: { "1234" }, imported: nil) }
        let firstReached = await Task.detached { host.waitForTouch() }.value
        XCTAssertTrue(firstReached)
        let first = try XCTUnwrap(host.state.touch)
        try registry.touch(id: other, expected: first)
        XCTAssertEqual(host.state.touch, first)
        try registry.touch(id: id, expected: first)
        let secondReached = await Task.detached { host.waitForTouch(after: 1) }.value
        XCTAssertTrue(secondReached)
        let second = try XCTUnwrap(host.state.touch)
        XCTAssertNotEqual(first, second)
        try registry.touch(id: id, expected: first)
        try registry.touch(id: id, expected: second)
        let result = try await task.value
        XCTAssertTrue(result.0.account.canDerive)
        XCTAssertNotNil(result.1)
        XCTAssertEqual(host.touchCount, 2)
    }

    func testOrdinaryTouchTimeoutLeavesHostAndExistingCredentialsUsable() async throws {
        let registry = try registry(timeout: 100)
        defer { registry.stop() }
        let id = try registry.add()
        let core = registry.core
        let devicePath = try path(registry, id)
        try core.setInitialPIN(devicePath: devicePath, newPIN: "1234")
        let account = try core.enroll(accountId: "vault", identity: .random(), devicePath: devicePath, askPIN: { "1234" })
        let host = try registry.host(id: id)
        try host.configurePresence(.controlled)
        let result = await Task.detached { Result { try core.generatePassword(account, label: "master", pinProvider: { "1234" }) } }.value
        if case .success = result { XCTFail("An untouched key generated a password") }
        XCTAssertNil(host.state.failure)
        XCTAssertNil(host.state.touch)
        XCTAssertEqual(try core.enumerateAccounts(devicePath: devicePath, pin: "1234").count, 1)
    }

    func testStoppingAHungHostDoesNotWaitForItsRequestDeadline() async throws {
        let registry = try registry()
        defer { registry.stop() }
        let id = try registry.add()
        let host = try registry.host(id: id)
        try host.begin(operation: .hang, payload: Data())
        let task = Task.detached { Result { try host.finish(timeoutMilliseconds: 35_000) } }
        let start = ContinuousClock.now
        host.stop()
        if case .success = await task.value { XCTFail("Stopped host returned a response") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(registry.snapshot.devices.first?.connection, .stopped)
        XCTAssertTrue(try registry.listDevices().isEmpty)
        XCTAssertThrowsError(try registry.attach(id: id))
        host.stop()
    }

    func testClosedOldConnectionCannotReleaseANewOpen() throws {
        let registry = try registry()
        defer { registry.stop() }
        let id = try registry.add()
        let old = try registry.connect(path: path(registry, id))
        old.close()
        try registry.disconnect(id: id)
        try registry.attach(id: id)
        let newPath = try path(registry, id)
        let current = try registry.connect(path: newPath)
        defer { current.close() }
        old.close()
        XCTAssertThrowsError(try registry.connect(path: newPath))
    }

    func testUnplugBetweenSendAndReceiveDrainsTheReplyBeforeReconnect() async throws {
        let registry = try registry()
        defer { registry.stop() }
        let id = try registry.add()
        let devicePath = try path(registry, id)
        try registry.core.setInitialPIN(devicePath: devicePath, newPIN: "1234")
        let connection = try registry.connect(path: devicePath)
        defer { connection.close() }
        try connection.send(command: 0x10, payload: Data([0x04]))
        let unplug = Task.detached { try registry.disconnect(id: id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while registry.snapshot.devices.first?.connection == .connected, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(registry.snapshot.devices.first?.connection, .disconnecting)
        XCTAssertThrowsError(try connection.receive(command: 0x10, capacity: 4096, timeoutMilliseconds: 1_000))
        connection.close()
        try await unplug.value
        try registry.attach(id: id)
        XCTAssertTrue(try registry.core.status(devicePath: path(registry, id)).hasPIN)
    }

    func testMissingHelperNeverCreatesADeviceOrFallsBackToHardware() throws {
        let registry = VirtualDeviceRegistry(executable: URL(fileURLWithPath: "/missing/fidopass-test-authenticator"))
        XCTAssertThrowsError(try registry.add())
        XCTAssertTrue(try registry.core.listDevices().isEmpty)
        XCTAssertThrowsError(try registry.core.status(devicePath: "ioreg://physical"))
    }
}
