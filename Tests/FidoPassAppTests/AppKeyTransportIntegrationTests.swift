import XCTest
import FidoPassCore
import TestSupport
import FidoPassVirtualKeys
@testable import FidoPassAppKit

@MainActor
final class AppKeyTransportIntegrationTests: AppTestCase {
    func testAbandonedLiveEnrollmentCanCommitWithoutResurrectingClosedPanel() async throws {
        if !FileManager.default.isExecutableFile(atPath: OpenSKHostClient.executable.path),
           ProcessInfo.processInfo.environment["FIDOPASS_REQUIRE_KEY_TESTS"] != "1" {
            throw XCTSkip("Run scripts/test_keys.sh")
        }
        let registry = try TestVirtualDeviceRegistry()
        let core = registry.core
        let path = try XCTUnwrap(core.listDevices().first?.path)
        // Fixture preparation is confined to the virtual key's own worker.
        let worker = KeyWorker(backend: LiveKeyBackend(core: core))
        try await worker.admin { try $0.setInitialPIN(devicePath: path, newPIN: "1234") }
        let container = AppTestFactory.makeContainer(backend: LiveKeyBackend(core: core))
        let panel = container.panel
        await panel.prepareForDisplay()
        panel.pinDraft = "1234"
        await panel.submitPin()
        let host = try registry.host(path: path)
        try host.configurePresence(.controlled)
        panel.enrollDraft.accountId = "vault"
        panel.enrollDraft.mode = .local
        panel.show(.enroll)
        let task = Task { await panel.createAccount() }
        let reached = await Task.detached { host.waitForTouch() }.value
        XCTAssertTrue(reached)
        panel.panelDidClose()
        XCTAssertTrue(panel.touchGate.isWorking, "Hiding the prompt does not cancel a physical operation")
        try host.grantTouch()
        await task.value
        XCTAssertNil(panel.backup)
        XCTAssertNil(panel.generation.result)
        XCTAssertTrue(panel.accounts.accounts.isEmpty)
        XCTAssertFalse(panel.touchGate.isWorking)
        let actual = try await worker.accounts { try $0.enumerateAccounts(devicePath: path, pin: "1234") }
        XCTAssertEqual(actual.count, 1, "OpenSK commits after the user abandons the UI")
        await panel.prepareForDisplay()
        XCTAssertEqual(panel.accounts.accounts.count, 1, "The next explicit read reconciles the committed mutation")
    }
}
