import XCTest
import Foundation
@testable import FidoPassCore
import TestSupport
import FidoPassVirtualKeys

final class KeyTransportIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        if !FileManager.default.isExecutableFile(atPath: OpenSKHostClient.executable.path),
           ProcessInfo.processInfo.environment["FIDOPASS_REQUIRE_KEY_TESTS"] != "1" {
            throw XCTSkip("Run bash scripts/test_keys.sh to prepare the required OpenSK helper")
        }
    }

    func testRealCoreLocalAccountRoundTrip() throws {
        let registry = try TestVirtualDeviceRegistry()
        let core = registry.core
        let path = try XCTUnwrap(core.listDevices().first?.path)
        XCTAssertFalse(try core.status(devicePath: path).hasPIN)
        try core.setInitialPIN(devicePath: path, newPIN: "1234")
        let account = try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" })
        let first = try core.generatePassword(account, label: "master", pinProvider: { "1234" })
        let accounts = try core.enumerateAccounts(devicePath: path, pin: "1234")
        XCTAssertEqual(accounts.count, 1)
        let restored = try XCTUnwrap(accounts.first)
        XCTAssertTrue(restored.account.canDerive)
        let second = try core.generatePassword(restored, label: "master", pinProvider: { "1234" })
        XCTAssertTrue(first.utf8.elementsEqual(second.utf8), "Password changed across real transport reopen")
        try core.deleteAccount(restored, pin: "1234")
        XCTAssertTrue(try core.enumerateAccounts(devicePath: path, pin: "1234").isEmpty)
        XCTAssertEqual(registry.openCount, registry.closeCount)
    }

    func testPortableBackupAcrossIndependentKeys() throws {
        let registry = try TestVirtualDeviceRegistry(count: 2)
        let core = registry.core
        let paths = try core.listDevices().map(\.path)
        for path in paths { try core.setInitialPIN(devicePath: path, newPIN: "1234") }
        let identity = AccountIdentity.random()
        let (first, backup) = try core.enrollPortable(accountId: "vault", identity: identity, devicePath: paths[0], askPIN: { "1234" }, imported: nil)
        let (second, _) = try core.enrollPortable(accountId: "vault", identity: identity, devicePath: paths[1], askPIN: { "1234" }, imported: XCTUnwrap(backup))
        let a = try core.generatePassword(first, label: "master", pinProvider: { "1234" })
        let b = try core.generatePassword(second, label: "master", pinProvider: { "1234" })
        XCTAssertTrue(a.utf8.elementsEqual(b.utf8), "Imported backup must preserve the password")
        XCTAssertEqual(registry.openCount, registry.closeCount)
    }

    func testUnknownPathNeverFallsBackToHardware() throws {
        let registry = try TestVirtualDeviceRegistry()
        XCTAssertThrowsError(try registry.core.status(devicePath: "ioreg://not-a-test-device"))
        XCTAssertEqual(registry.openCount, 0)
    }

    func testIdentityCollisionCannotReplaceExistingCredential() throws {
        let registry = try TestVirtualDeviceRegistry()
        let core = registry.core
        let path = try XCTUnwrap(core.listDevices().first?.path)
        try core.setInitialPIN(devicePath: path, newPIN: "1234")
        let identity = AccountIdentity.random()
        let original = try core.enroll(accountId: "first", identity: identity, devicePath: path, askPIN: { "1234" })
        let before = registry.commands.filter { $0 == 1 }.count
        XCTAssertThrowsError(try core.enroll(accountId: "different-name", identity: identity, devicePath: path, askPIN: { "1234" }))
        XCTAssertEqual(registry.commands.filter { $0 == 1 }.count, before)
        XCTAssertNoThrow(try core.generatePassword(original, label: "master", pinProvider: { "1234" }))
    }

    func testFailedPreflightNeverCreatesCredential() throws {
        let registry = try TestVirtualDeviceRegistry()
        let core = registry.core
        let path = try XCTUnwrap(core.listDevices().first?.path)
        try core.setInitialPIN(devicePath: path, newPIN: "1234")
        try registry.inject(.reject(command: 0x0a, status: 0x31), path: path)
        XCTAssertThrowsError(try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" }))
        XCTAssertFalse(registry.commands.contains(1))
    }

    func testLostCreationReplyLeavesObservableCredential() throws {
        let registry = try TestVirtualDeviceRegistry()
        let core = registry.core
        let path = try XCTUnwrap(core.listDevices().first?.path)
        try core.setInitialPIN(devicePath: path, newPIN: "1234")
        try registry.inject(.loseReply(command: 1), path: path)
        XCTAssertThrowsError(try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" }))
        let leftovers = try core.enumerateAccounts(devicePath: path, pin: "1234")
        XCTAssertEqual(leftovers.count, 1)
        XCTAssertEqual(leftovers.first?.account.integrity, .recordMissing)
        XCTAssertEqual(registry.openCount, registry.closeCount)
    }

    func testPowerCycleChangesPathButPreservesCredentialsAndPermitsReset() throws {
        let registry = try TestVirtualDeviceRegistry()
        let core = registry.core
        let oldPath = try XCTUnwrap(core.listDevices().first?.path)
        try core.setInitialPIN(devicePath: oldPath, newPIN: "1234")
        _ = try core.enroll(accountId: "vault", identity: .random(), devicePath: oldPath, askPIN: { "1234" })
        let newPath = try registry.powerCycle(path: oldPath)
        XCTAssertNotEqual(oldPath, newPath)
        XCTAssertThrowsError(try core.status(devicePath: oldPath))
        XCTAssertEqual(try core.enumerateAccounts(devicePath: newPath, pin: "1234").count, 1)
        let resetPath = try registry.powerCycle(path: newPath)
        try core.resetDevice(devicePath: resetPath)
        XCTAssertFalse(try core.status(devicePath: resetPath).hasPIN)
    }
}

extension KeyTransportIntegrationTests {
    private func prepared(profile: OpenSKHostClient.Profile = .standard, hid: Bool = false) throws -> (TestVirtualDeviceRegistry, FidoPassCore, String) {
        let registry = try TestVirtualDeviceRegistry(profile: profile, hid: hid)
        let core = registry.core
        let path = try XCTUnwrap(core.listDevices().first?.path)
        try core.setInitialPIN(devicePath: path, newPIN: "1234")
        return (registry, core, path)
    }

    func testWrongPINInventorySpendsExactlyOneAttempt() throws {
        let (registry, core, path) = try prepared()
        let before = try XCTUnwrap(core.status(devicePath: path).pinRetriesRemaining)
        XCTAssertThrowsError(try core.inventory(devicePath: path, pin: "9999"))
        XCTAssertEqual(try core.status(devicePath: path).pinRetriesRemaining, before - 1)
        XCTAssertEqual(registry.openCount, registry.closeCount)
    }

    func testFailedCredentialDeletionPreservesPortableRecordAndPassword() throws {
        let (registry, core, path) = try prepared()
        let (account, _) = try core.enrollPortable(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" }, imported: nil)
        let password = try core.generatePassword(account, label: "master", pinProvider: { "1234" })
        try registry.inject(.rejectSubcommand(command: 0x0a, subcommand: 6, status: 0x27), path: path)
        XCTAssertThrowsError(try core.deleteAccount(account, pin: "1234"))
        let reloaded = try XCTUnwrap(core.enumerateAccounts(devicePath: path, pin: "1234").first)
        XCTAssertEqual(reloaded.account.integrity, .ok)
        let after = try core.generatePassword(reloaded, label: "master", pinProvider: { "1234" })
        XCTAssertTrue(password.utf8.elementsEqual(after.utf8))
    }

    func testBlobTransportErrorIsNotReportedAsMissingRecord() throws {
        let (registry, core, path) = try prepared()
        _ = try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" })
        try registry.inject(.loseReply(command: 0x0c), path: path)
        XCTAssertThrowsError(try core.enumerateAccounts(devicePath: path, pin: "1234"))
        XCTAssertEqual(try core.enumerateAccounts(devicePath: path, pin: "1234").first?.account.integrity, .ok)
    }

    func testMalformedOpenReplyClosesItsContext() throws {
        let registry = try TestVirtualDeviceRegistry()
        let path = try XCTUnwrap(registry.core.listDevices().first?.path)
        for _ in 0..<2 { try registry.inject(.malformed(command: 4, reply: Data([0, 0xff])), path: path) }
        XCTAssertThrowsError(try registry.core.status(devicePath: path))
        XCTAssertEqual(registry.openCount, registry.closeCount)
        XCTAssertNoThrow(try registry.core.status(devicePath: path))
    }

    func testLegacyPortableMigrationPreservesActualPassword() throws {
        let (registry, core, path) = try prepared()
        try registry.host(path: path).prepareLegacy(portable: true)
        let old = try XCTUnwrap(core.enumerateAccounts(devicePath: path, pin: "1234").first)
        XCTAssertEqual(old.account.format, .v1)
        let before = try core.generatePassword(old, label: "master", pinProvider: { "1234" })
        let migrated = try core.migrate(old, identity: .random(), askPIN: { "1234" })
        let after = try core.generatePassword(migrated, label: "master", pinProvider: { "1234" })
        XCTAssertTrue(before.utf8.elementsEqual(after.utf8))
        let all = try core.enumerateAccounts(devicePath: path, pin: "1234")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.account.format, .v2)
    }

    func testHIDReportsExerciseRealLibfidoFramingWithLargeBlobAndAssertion() throws {
        let (registry, core, path) = try prepared(hid: true)
        let account = try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" })
        XCTAssertNoThrow(try core.generatePassword(account, label: "master", pinProvider: { "1234" }))
        XCTAssertEqual(try core.enumerateAccounts(devicePath: path, pin: "1234").count, 1)
        XCTAssertEqual(registry.openCount, registry.closeCount)
        XCTAssertTrue(registry.commands.isEmpty, "HID mode must not use command-level callbacks")
    }

    func testResidentLimitIsEnforcedByEngine() throws {
        let (_, core, path) = try prepared(profile: .twoSlots)
        for name in ["one", "two"] {
            _ = try core.enroll(accountId: name, identity: .random(), devicePath: path, askPIN: { "1234" })
        }
        XCTAssertThrowsError(try core.enroll(accountId: "three", identity: .random(), devicePath: path, askPIN: { "1234" }))
        XCTAssertEqual(try core.enumerateAccounts(devicePath: path, pin: "1234").count, 2)
    }

    func testSettingsAndEnterpriseProfilesUseActualEngine() throws {
        let (_, core, path) = try prepared(profile: .enterprise)
        XCTAssertTrue(try core.toggleAlwaysUV(devicePath: path, pin: "1234"))
        XCTAssertFalse(try core.toggleAlwaysUV(devicePath: path, pin: "1234"))
        try core.enableEnterpriseAttestation(devicePath: path, pin: "1234")
        try core.setMinimumPINLength(devicePath: path, length: 6, pin: "1234")
        XCTAssertEqual(try core.status(devicePath: path).minPINLength, 6)
        XCTAssertTrue(try core.status(devicePath: path).forcePINChange)
    }

    func testTouchTimeoutAndExpiredResetAreDifferentEngineResponses() throws {
        let (registry, core, path) = try prepared()
        let host = try registry.host(path: path)
        try host.configurePresence(.timeout)
        XCTAssertThrowsError(try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" })) { error in
            XCTAssertEqual(KeyFailurePolicy.status(of: error), .userActionTimeout)
        }
        try host.configurePresence(.immediate)
        let replugged = try registry.powerCycle(path: path)
        try host.advanceClock(milliseconds: 15_000)
        XCTAssertThrowsError(try core.resetDevice(devicePath: replugged)) { error in
            XCTAssertEqual(KeyFailurePolicy.status(of: error), .notAllowed)
        }
    }

    func testControlledTouchUsesIndependentControlChannel() async throws {
        let (registry, core, path) = try prepared()
        let host = try registry.host(path: path)
        try host.configurePresence(.controlled)
        let operation = Task.detached { try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { "1234" }) }
        XCTAssertTrue(host.waitForTouch())
        try host.grantTouch()
        _ = try await operation.value
        XCTAssertEqual(try core.enumerateAccounts(devicePath: path, pin: "1234").count, 1)
    }
}

extension KeyTransportIntegrationTests {
    func testVerifiedMigrationCopySurvivesFailedOriginalDeletionAndCanFinish() throws {
        let (registry, core, path) = try prepared()
        try registry.host(path: path).prepareLegacy(portable: true)
        let old = try XCTUnwrap(core.enumerateAccounts(devicePath: path, pin: "1234").first)
        let before = try core.generatePassword(old, label: "master", pinProvider: { "1234" })
        try registry.inject(.rejectSubcommand(command: 0x0a, subcommand: 6, status: 0x27), path: path)
        XCTAssertThrowsError(try core.migrate(old, identity: .random(), askPIN: { "1234" }))
        let all = try core.enumerateAccounts(devicePath: path, pin: "1234")
        XCTAssertEqual(all.count, 2)
        let copy = try XCTUnwrap(all.first { $0.account.format == .v2 })
        let finished = try core.finishMigration(old: old, copy: copy, askPIN: { "1234" })
        let after = try core.generatePassword(finished, label: "master", pinProvider: { "1234" })
        XCTAssertTrue(before.utf8.elementsEqual(after.utf8))
        XCTAssertEqual(try core.enumerateAccounts(devicePath: path, pin: "1234").count, 1)
    }

    func testMissingRecordDoesNotBypassIdentityCollisionPreflight() throws {
        let (registry, core, path) = try prepared()
        let identity = AccountIdentity.random()
        try registry.inject(.loseReply(command: 1), path: path)
        XCTAssertThrowsError(try core.enroll(accountId: "lost", identity: identity, devicePath: path, askPIN: { "1234" }))
        let count = registry.commands.filter { $0 == 1 }.count
        XCTAssertThrowsError(try core.enroll(accountId: "replacement", identity: identity, devicePath: path, askPIN: { "1234" }))
        XCTAssertEqual(registry.commands.filter { $0 == 1 }.count, count)
    }

    func testLegacyDisplayPayloadIsReadableButAbsentFromInventoryExport() throws {
        let (registry, core, path) = try prepared()
        try registry.host(path: path).prepareLegacy(portable: true, displayPayload: true)
        let account = try XCTUnwrap(core.enumerateAccounts(devicePath: path, pin: "1234").first)
        XCTAssertTrue(account.account.canDerive)
        let inventory = try core.inventory(devicePath: path, pin: "1234")
        let json = String(decoding: try JSONEncoder().encode(inventory), as: UTF8.self)
        XCTAssertFalse(json.contains("fp-ext:v1:"))
        XCTAssertFalse(json.contains("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
    }

    func testHungHelperIsKilledAtReadDeadlineAndCannotBeReused() throws {
        let host = try OpenSKHostClient(seed: 1)
        try host.begin(operation: .hang, payload: Data())
        let start = ContinuousClock.now
        XCTAssertThrowsError(try host.finish(timeoutMilliseconds: 30))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertThrowsError(try host.begin(payload: Data([4])))
        host.stop() // Idempotent after timeout/reaping.
    }

    func testConcurrentKeysHaveIndependentPINAndStorage() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    let registry = try TestVirtualDeviceRegistry()
                    let core = registry.core
                    let path = try XCTUnwrap(core.listDevices().first?.path)
                    let pin = "1234\(index)"
                    try core.setInitialPIN(devicePath: path, newPIN: pin)
                    _ = try core.enroll(accountId: "vault", identity: .random(), devicePath: path, askPIN: { pin })
                    XCTAssertEqual(try core.enumerateAccounts(devicePath: path, pin: pin).count, 1)
                    XCTAssertEqual(registry.openCount, registry.closeCount)
                }
            }
            try await group.waitForAll()
        }
    }
}

extension KeyTransportIntegrationTests {
    func testHIDRejectsOutOfOrderContinuationAndUnknownChannel() throws {
        let host = try OpenSKHostClient(seed: 1)
        var initPacket = Data(repeating: 0, count: 64)
        initPacket.replaceSubrange(0..<4, with: [255, 255, 255, 255])
        initPacket[4] = 0x86; initPacket[6] = 8
        initPacket.replaceSubrange(7..<15, with: Array(repeating: UInt8(7), count: 8))
        try host.begin(operation: .hid, payload: initPacket)
        let initReply = try host.finish(timeoutMilliseconds: 1_000)
        XCTAssertEqual(initReply.count, 64)
        let channel = initReply.subdata(in: 15..<19)
        var initial = Data(repeating: 0, count: 64)
        initial.replaceSubrange(0..<4, with: channel)
        initial[4] = 0x90; initial[6] = 60; initial[7] = 4
        try host.begin(operation: .hid, payload: initial)
        XCTAssertTrue(try host.finish(timeoutMilliseconds: 1_000).isEmpty)
        var continuation = Data(repeating: 0, count: 64)
        continuation.replaceSubrange(0..<4, with: channel)
        continuation[4] = 1 // Sequence zero was skipped.
        try host.begin(operation: .hid, payload: continuation)
        let error = try host.finish(timeoutMilliseconds: 1_000)
        XCTAssertEqual(error[4], 0xbf)
        XCTAssertEqual(error[7], 4)
        initial.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        initial[6] = 1
        try host.begin(operation: .hid, payload: initial)
        let unknown = try host.finish(timeoutMilliseconds: 1_000)
        XCTAssertEqual(unknown[4], 0xbf)
        XCTAssertEqual(unknown[7], 0x0b)
    }

    func testSmallBlobCapacityRejectsNewAccountWithoutDamagingExistingOnes() throws {
        let (_, core, path) = try prepared(profile: .smallBlob)
        var created = 0
        for index in 0..<24 {
            do {
                _ = try core.enrollPortable(accountId: "vault\(index)", identity: .random(), devicePath: path, askPIN: { "1234" }, imported: nil)
                created += 1
            } catch { break }
        }
        XCTAssertGreaterThan(created, 0)
        XCTAssertLessThan(created, 24, "The engine must enforce the configured byte capacity")
        let survivors = try core.enumerateAccounts(devicePath: path, pin: "1234")
        XCTAssertEqual(survivors.count, created)
        XCTAssertTrue(survivors.allSatisfy { $0.account.canDerive })
    }
}
