import Foundation

/// Moves a portable v1 account to the v2 layout by recreating it.
///
/// The material of a portable account is its master key, which the credential only masks;
/// a new credential with the same master key derives the same passwords and issues the
/// same message keys. So the copy is made, the master key is read back **through the copy**
/// by the ordinary path — enumerate, record, recover — and compared, and only then is the
/// original deleted. Any failure before that deletes the copy instead. Four touches.
///
/// The copy is created under the original's own name and with no marker of any kind: a
/// name is a name. The pair "v1 and v2 with one name on one key" can arise no other way,
/// because ordinary creation refuses a taken name under every relying party, and that is
/// how an interrupted migration is recognised and finished.
///
/// A local v1 account has no master key — its secrets are the credential's own and cannot
/// be moved — so it does not migrate, and is refused here.
final class AccountMigrationService: Migrating, Sendable {
    private let enrollmentService: Enrolling
    private let secretDerivationService: SecretDeriving

    init(enrollmentService: Enrolling, secretDerivationService: SecretDeriving) {
        self.enrollmentService = enrollmentService
        self.secretDerivationService = secretDerivationService
    }

    func migrate(_ old: AccountHandle,
                 identity: AccountIdentity,
                 askPIN: (@Sendable () -> String?)?,
                 onStep: (@Sendable (MigrationStep) -> Void)?) throws -> AccountHandle {
        try Self.requireMigratable(old)
        if let pin = askPIN?(), !pin.isEmpty,
           let existing = try? enrollmentService.enumerateAccounts(devicePath: old.devicePath, pin: pin),
           existing.contains(where: { $0.id == old.id && $0.account.format == .v2 }) {
            throw MigrationError.copyExists(name: old.id)
        }

        onStep?(.readingOldAccount)
        let masterKey = try PortableMasterKey.recover(old, using: secretDerivationService, pinProvider: askPIN)

        onStep?(.creatingCredential)
        var copy = try enrollmentService.enroll(accountId: old.id,
                                                kind: .portable,
                                                identity: identity,
                                                devicePath: old.devicePath,
                                                askPIN: askPIN,
                                                namesakePolicy: .allowLegacyTwin)
        // From here on the copy is on the key: a failure has to take it back off.
        let verified: AccountHandle
        do {
            onStep?(.derivingNewComponent)
            let fixed = try PortableMasterKey.fixedComponent(copy, using: secretDerivationService, pinProvider: askPIN)
            copy.account.mask = PortableMasterKey.combine(masterKey, fixed)

            onStep?(.savingRecord)
            try enrollmentService.writeRecord(for: copy, pinProvider: askPIN)
            copy.account.integrity = .ok

            onStep?(.verifying)
            verified = try verify(copy: copy, masterKey: masterKey, askPIN: askPIN)
        } catch {
            onStep?(.rollingBack)
            do {
                try enrollmentService.deleteAccount(copy, pin: askPIN?())
            } catch let rollbackFailure {
                throw MigrationError.copyRemains(name: old.id, reason: Self.describe(error) + "; " + Self.describe(rollbackFailure))
            }
            throw error
        }

        onStep?(.deletingOld)
        try enrollmentService.deleteAccount(old, pin: askPIN?())
        return verified
    }

    func finishMigration(old: AccountHandle,
                         copy: AccountHandle,
                         askPIN: (@Sendable () -> String?)?,
                         onStep: (@Sendable (MigrationStep) -> Void)?) throws -> AccountHandle {
        try Self.requireMigratable(old)
        guard copy.account.format == .v2, copy.id == old.id, copy.devicePath == old.devicePath else {
            throw MigrationError.notMigratable("“\(copy.id)” is not an unfinished copy of “\(old.id)”")
        }

        // A copy without a record got as far as the credential and no further. Nothing in it
        // is worth keeping except the identity, which the person has already seen.
        guard copy.account.canDerive else {
            onStep?(.rollingBack)
            try enrollmentService.deleteAccount(copy, pin: askPIN?())
            guard let identity = copy.account.identity else {
                throw MigrationError.notMigratable("The unfinished copy carried no identity; it was removed — migrate again")
            }
            return try migrate(old, identity: identity, askPIN: askPIN, onStep: onStep)
        }

        onStep?(.readingOldAccount)
        let masterKey = try PortableMasterKey.recover(old, using: secretDerivationService, pinProvider: askPIN)

        onStep?(.verifying)
        let verified = try verify(copy: copy, masterKey: masterKey, askPIN: askPIN)

        onStep?(.deletingOld)
        try enrollmentService.deleteAccount(old, pin: askPIN?())
        return verified
    }

    func discardMigrationCopy(_ copy: AccountHandle, pin: String?) throws {
        guard copy.account.format == .v2 else {
            throw MigrationError.notMigratable("“\(copy.id)” is not a migration copy")
        }
        try enrollmentService.deleteAccount(copy, pin: pin)
    }

    // MARK: - Helpers

    /// Reads the copy back from the key — record included — and recovers the master key
    /// through it. The production path, not the values in memory: this is what proves the
    /// write, not just the arithmetic. A touch.
    private func verify(copy: AccountHandle,
                        masterKey: Data,
                        askPIN: (@Sendable () -> String?)?) throws -> AccountHandle {
        let onKey = try enrollmentService.enumerateAccounts(devicePath: copy.devicePath, pin: askPIN?())
        guard let fresh = onKey.first(where: { $0.account.format == .v2 && $0.credentialIdB64 == copy.credentialIdB64 }) else {
            throw MigrationError.copyNotFound
        }
        guard fresh.account.canDerive, fresh.account.kind == .portable else {
            throw MigrationError.verificationFailed
        }
        let recovered = try PortableMasterKey.recover(fresh, using: secretDerivationService, pinProvider: askPIN)
        guard recovered == masterKey else {
            throw MigrationError.verificationFailed
        }
        return fresh
    }

    private static func requireMigratable(_ handle: AccountHandle) throws {
        guard handle.account.format == .v1 else {
            throw MigrationError.notMigratable("“\(handle.id)” is already in the current format")
        }
        guard handle.account.kind == .portable else {
            throw MigrationError.notMigratable("“\(handle.id)” is a local account: its material cannot be moved to a new credential, so it stays as it is")
        }
        guard handle.account.canDerive else {
            throw MigrationError.notMigratable("“\(handle.id)” has no readable key material to migrate")
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
