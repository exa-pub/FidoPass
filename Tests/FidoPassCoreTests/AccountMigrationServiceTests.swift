import XCTest
@testable import FidoPassCore
import TestSupport

/// The migration is a sequence with one invariant: the original is deleted only after the
/// copy has been read back from the key and shown to derive the same master key. Every
/// failure before that point removes the copy instead; every state an interruption can
/// leave is one `finishMigration` converges from.
final class AccountMigrationServiceTests: XCTestCase {

    /// A key in memory: what is on it, and what each credential answers for its fixed
    /// component. Enrolment, record writes and deletions change it the way the real ones
    /// would, so `enumerate` afterwards shows the state a re-read would.
    private final class FakeKey: @unchecked Sendable {
        let enrollment = MockEnrollmentService()
        let secrets = MockSecretDerivationService()
        var accounts: [AccountHandle]
        var fixedByCredential: [String: Data]
        var nextCredential = 1
        var failEnroll: Error?
        var failFixed: [String: Error] = [:]
        var failWriteRecord: Error?
        var failDelete: [String: Error] = [:]
        /// When set, the record written is not the one asked for — a key that lost the write.
        var corruptWrittenMask = false

        init(old: AccountHandle, oldFixed: Data) {
            accounts = [old]
            fixedByCredential = [old.credentialIdB64: oldFixed]

            enrollment.enumerateClosure = { [unowned self] _, _ in self.accounts }
            enrollment.enrollClosure = { [unowned self] id, kind, identity, path, _, _ in
                if let failEnroll { throw failEnroll }
                let credential = Data("copy-\(nextCredential)".utf8)
                nextCredential += 1
                fixedByCredential[credential.base64EncodedString()] = Data(repeating: UInt8(0x40 + nextCredential), count: 32)
                let handle = AccountHandle.v2Fixture(id: id, kind: kind, credentialId: credential, identity: identity,
                                                     mask: nil, devicePath: path, integrity: .recordMissing)
                accounts.append(handle)
                return handle
            }
            enrollment.writeRecordClosure = { [unowned self] handle, _ in
                if let failWriteRecord { throw failWriteRecord }
                guard let index = accounts.firstIndex(where: { $0.credentialIdB64 == handle.credentialIdB64 }) else {
                    throw TestError.generic("no such credential")
                }
                var stored = handle
                if corruptWrittenMask { stored.account.mask = Data(repeating: 0xEE, count: 32) }
                stored.account.integrity = .ok
                accounts[index] = stored
            }
            enrollment.deleteClosure = { [unowned self] handle, _ in
                if let failure = failDelete[handle.credentialIdB64] { throw failure }
                accounts.removeAll { $0.credentialIdB64 == handle.credentialIdB64 }
            }
            secrets.deriveFixedClosure = { [unowned self] handle, _ in
                if let failure = failFixed[handle.credentialIdB64] { throw failure }
                guard let fixed = fixedByCredential[handle.credentialIdB64] else { throw TestError.generic("unknown credential") }
                return fixed
            }
        }

        var service: AccountMigrationService {
            AccountMigrationService(enrollmentService: enrollment, secretDerivationService: secrets)
        }

        var v1: [AccountHandle] { accounts.filter { $0.account.format == .v1 } }
        var v2: [AccountHandle] { accounts.filter { $0.account.format == .v2 } }
    }

    private let identity = AccountIdentity(hex: "0102030405060708090a0b0c0d0e0f10")!
    private let oldFixed = Data(repeating: 0x0F, count: 32)
    private let masterKey = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ 1) })

    private func legacy(named id: String = "vault") -> AccountHandle {
        let external = Data(zip(masterKey, oldFixed).map { $0 ^ $1 })
        return AccountHandle.fixture(id: id, kind: .portable, credentialId: Data("old-\(id)".utf8),
                                     devicePath: "/dev/one", portable: PortablePayload(external: external))
    }

    private func recovered(_ handle: AccountHandle, on key: FakeKey) throws -> Data {
        try PortableMasterKey.recover(handle, using: key.secrets, pinProvider: nil)
    }

    // MARK: - The happy path

    func testMigrationRecreatesTheAccountWithTheSameMasterKey() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        nonisolated(unsafe) var steps: [MigrationStep] = []

        let migrated = try key.service.migrate(old, identity: identity, askPIN: { "1234" }, onStep: { steps.append($0) })

        XCTAssertEqual(steps, [.readingOldAccount, .creatingCredential, .derivingNewComponent, .savingRecord, .verifying, .deletingOld])
        XCTAssertEqual(migrated.id, "vault")
        XCTAssertEqual(migrated.account.format, .v2)
        XCTAssertEqual(migrated.kind, .portable)
        XCTAssertEqual(migrated.account.identity, identity)
        XCTAssertEqual(migrated.account.integrity, .ok)
        XCTAssertEqual(key.secrets.deriveFixedCalls.count, 3, "old, new, and the verification read-back")
        XCTAssertEqual(try recovered(migrated, on: key), masterKey, "the copy derives the same master key")
        XCTAssertTrue(key.v1.isEmpty, "the original is gone")
        XCTAssertEqual(key.v2.map(\.id), ["vault"])
        XCTAssertEqual(key.enrollment.enrollCalls.first?.namesakePolicy, .allowLegacyTwin)
    }

    /// The invariant, as an ordering: the old credential is deleted after the copy has been
    /// re-read and verified, and after nothing else.
    func testTheOriginalIsDeletedLastAndOnlyAfterVerification() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        _ = try key.service.migrate(old, identity: identity, askPIN: { "1234" }, onStep: nil)

        let log = key.enrollment.callLog
        XCTAssertEqual(log.last, "delete(vault:v1)")
        let write = try XCTUnwrap(log.firstIndex(of: "writeRecord(vault)"))
        let reread = try XCTUnwrap(log.lastIndex(of: "enumerate"))
        let delete = try XCTUnwrap(log.firstIndex(of: "delete(vault:v1)"))
        XCTAssertLessThan(write, reread, "the record is written, then read back")
        XCTAssertLessThan(reread, delete, "and only then is the original deleted")
        XCTAssertFalse(log.contains("delete(vault:v2)"), "the copy is never deleted on the happy path")
    }

    // MARK: - Failures before the point of no return

    func testAFailedCredentialLeavesEverythingAsItWas() {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        key.failEnroll = TestError.generic("no touch")

        XCTAssertThrowsError(try key.service.migrate(old, identity: identity, askPIN: nil, onStep: nil))
        XCTAssertEqual(key.accounts, [old])
    }

    func testAFailedFixedComponentRemovesTheCopy() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        key.failFixed[Data("copy-1".utf8).base64EncodedString()] = TestError.generic("no touch")
        nonisolated(unsafe) var steps: [MigrationStep] = []

        XCTAssertThrowsError(try key.service.migrate(old, identity: identity, askPIN: nil, onStep: { steps.append($0) })) { error in
            XCTAssertEqual(error as? TestError, .generic("no touch"))
        }
        XCTAssertEqual(steps.last, .rollingBack)
        XCTAssertEqual(key.accounts, [old], "the copy is gone, the original untouched")
    }

    func testAFailedRecordWriteRemovesTheCopy() {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        key.failWriteRecord = TestError.generic("store full")

        XCTAssertThrowsError(try key.service.migrate(old, identity: identity, askPIN: nil, onStep: nil))
        XCTAssertEqual(key.accounts, [old])
    }

    /// The verification is the point: a copy that does not reproduce the master key — the
    /// key kept something other than what was written — must never replace the original.
    func testACopyThatDerivesADifferentMasterKeyIsRemoved() {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        key.corruptWrittenMask = true

        XCTAssertThrowsError(try key.service.migrate(old, identity: identity, askPIN: nil, onStep: nil)) { error in
            XCTAssertEqual(error as? MigrationError, .verificationFailed)
        }
        XCTAssertEqual(key.accounts, [old])
    }

    /// When even the rollback fails — the key was pulled — the error says what is left.
    func testAFailedRollbackNamesTheCopyThatRemains() {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        key.failWriteRecord = TestError.generic("unplugged")
        key.failDelete[Data("copy-1".utf8).base64EncodedString()] = TestError.generic("unplugged")

        XCTAssertThrowsError(try key.service.migrate(old, identity: identity, askPIN: nil, onStep: nil)) { error in
            guard case .copyRemains(let name, _)? = error as? MigrationError else {
                return XCTFail("expected copyRemains, got \(error)")
            }
            XCTAssertEqual(name, "vault")
        }
        XCTAssertEqual(key.v1, [old])
        XCTAssertEqual(key.v2.count, 1, "the copy is still there for finish or discard")
    }

    // MARK: - Guards

    func testOnlyAPortableV1AccountMigrates() {
        let local = AccountHandle.fixture(id: "disk", kind: .local, devicePath: "/dev/one")
        let key = FakeKey(old: local, oldFixed: oldFixed)
        XCTAssertThrowsError(try key.service.migrate(local, identity: identity, askPIN: nil, onStep: nil)) { error in
            guard case .notMigratable? = error as? MigrationError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try key.service.migrate(AccountHandle.v2Fixture(id: "v", kind: .portable), identity: identity, askPIN: nil, onStep: nil))
        XCTAssertThrowsError(try key.service.migrate(AccountHandle.fixture(kind: .portable, portable: nil), identity: identity, askPIN: nil, onStep: nil),
                             "no readable material, nothing to move")
        XCTAssertTrue(key.enrollment.enrollCalls.isEmpty)
        XCTAssertTrue(key.secrets.deriveFixedCalls.isEmpty, "a refused migration costs no touch")
    }

    /// A copy already on the key means an earlier attempt got that far: making a second one
    /// would leave two, and `finish` is the way on.
    func testAnExistingCopyIsRefusedInFavourOfFinishing() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        key.failWriteRecord = TestError.generic("unplugged")
        key.failDelete[Data("copy-1".utf8).base64EncodedString()] = TestError.generic("unplugged")
        XCTAssertThrowsError(try key.service.migrate(old, identity: identity, askPIN: { "1234" }, onStep: nil))
        key.failWriteRecord = nil
        key.failDelete = [:]

        XCTAssertThrowsError(try key.service.migrate(old, identity: identity, askPIN: { "1234" }, onStep: nil)) { error in
            XCTAssertEqual(error as? MigrationError, .copyExists(name: "vault"))
        }
        XCTAssertEqual(key.v2.count, 1)
    }

    // MARK: - Finishing and discarding

    /// Interrupted before the record: the copy is discarded and the migration run again,
    /// with the identity the copy already had — the one the person saw.
    func testFinishingACopyWithoutARecordStartsOver() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        key.failWriteRecord = TestError.generic("unplugged")
        key.failDelete[Data("copy-1".utf8).base64EncodedString()] = TestError.generic("unplugged")
        XCTAssertThrowsError(try key.service.migrate(old, identity: identity, askPIN: nil, onStep: nil))
        key.failWriteRecord = nil
        key.failDelete = [:]
        let copy = try XCTUnwrap(key.v2.first)
        XCTAssertEqual(copy.account.integrity, .recordMissing)
        nonisolated(unsafe) var steps: [MigrationStep] = []

        let migrated = try key.service.finishMigration(old: old, copy: copy, askPIN: nil, onStep: { steps.append($0) })

        XCTAssertEqual(steps.first, .rollingBack)
        XCTAssertEqual(steps.last, .deletingOld)
        XCTAssertEqual(migrated.account.identity, identity, "the identity the copy carried is kept")
        XCTAssertEqual(try recovered(migrated, on: key), masterKey)
        XCTAssertTrue(key.v1.isEmpty)
        XCTAssertEqual(key.v2.count, 1)
        XCTAssertNotEqual(key.v2.first?.credentialIdB64, copy.credentialIdB64, "a fresh credential, not the half-made one")
    }

    /// Interrupted after the record: the copy is verified and the original deleted. Two
    /// touches, no new credential.
    func testFinishingACopyWithARecordVerifiesAndDeletesTheOriginal() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        // Build the copy by hand, as an interrupted migration would have left it.
        var copy = try key.enrollment.enroll(accountId: old.id, kind: .portable, identity: identity, devicePath: old.devicePath, askPIN: nil, namesakePolicy: .allowLegacyTwin)
        let newFixed = try XCTUnwrap(key.fixedByCredential[copy.credentialIdB64])
        copy.account.mask = Data(zip(masterKey, newFixed).map { $0 ^ $1 })
        try key.enrollment.writeRecord(for: copy, pinProvider: nil)
        copy.account.integrity = .ok
        let enrolsBefore = key.enrollment.enrollCalls.count
        nonisolated(unsafe) var steps: [MigrationStep] = []

        let migrated = try key.service.finishMigration(old: old, copy: copy, askPIN: nil, onStep: { steps.append($0) })

        XCTAssertEqual(steps, [.readingOldAccount, .verifying, .deletingOld])
        XCTAssertEqual(key.enrollment.enrollCalls.count, enrolsBefore, "no new credential")
        XCTAssertEqual(migrated.credentialIdB64, copy.credentialIdB64)
        XCTAssertTrue(key.v1.isEmpty)
        XCTAssertEqual(try recovered(migrated, on: key), masterKey)
    }

    /// A namesake that is not a copy of this account — different master key — must not
    /// cost the original its existence.
    func testFinishingRefusesACopyOfSomethingElse() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        var stranger = try key.enrollment.enroll(accountId: old.id, kind: .portable, identity: identity, devicePath: old.devicePath, askPIN: nil, namesakePolicy: .allowLegacyTwin)
        stranger.account.mask = Data(repeating: 0x99, count: 32)
        try key.enrollment.writeRecord(for: stranger, pinProvider: nil)
        stranger.account.integrity = .ok

        XCTAssertThrowsError(try key.service.finishMigration(old: old, copy: stranger, askPIN: nil, onStep: nil)) { error in
            XCTAssertEqual(error as? MigrationError, .verificationFailed)
        }
        XCTAssertEqual(key.v1, [old], "the original is untouched")
        XCTAssertEqual(key.v2.count, 1, "and the stranger is left for the person to discard")
    }

    func testFinishingNeedsAMatchingPair() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        let other = AccountHandle.v2Fixture(id: "other", kind: .portable, devicePath: "/dev/one")
        XCTAssertThrowsError(try key.service.finishMigration(old: old, copy: other, askPIN: nil, onStep: nil))
        let elsewhere = AccountHandle.v2Fixture(id: "vault", kind: .portable, devicePath: "/dev/two")
        XCTAssertThrowsError(try key.service.finishMigration(old: old, copy: elsewhere, askPIN: nil, onStep: nil))
        XCTAssertTrue(key.enrollment.deleteCalls.isEmpty)
    }

    func testDiscardingRemovesTheCopyAndNothingElse() throws {
        let old = legacy()
        let key = FakeKey(old: old, oldFixed: oldFixed)
        let copy = try key.enrollment.enroll(accountId: old.id, kind: .portable, identity: identity, devicePath: old.devicePath, askPIN: nil, namesakePolicy: .allowLegacyTwin)

        try key.service.discardMigrationCopy(copy, pin: "1234")

        XCTAssertEqual(key.accounts, [old])
        XCTAssertEqual(key.enrollment.deleteCalls.first?.1, "1234")
        XCTAssertThrowsError(try key.service.discardMigrationCopy(old, pin: "1234"), "the original is never 'discarded'")
    }
}
