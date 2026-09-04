import Foundation

final class PortableEnrollmentService: PortableEnrolling, Sendable {
    private let enrollmentService: Enrolling
    private let secretDerivationService: SecretDeriving

    init(enrollmentService: Enrolling,
         secretDerivationService: SecretDeriving) {
        self.enrollmentService = enrollmentService
        self.secretDerivationService = secretDerivationService
    }

    /// Creates a portable account and returns a backup only for a generated master key.
    /// Requires two touches (credential creation and fixed-component derivation), then a
    /// PIN-authenticated record write. Failures attempt credential cleanup.
    func enrollPortable(accountId: String,
                        identity: AccountIdentity,
                        devicePath: String,
                        askPIN: (@Sendable () -> String?)?,
                        imported: PortableBackup?,
                        onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (AccountHandle, PortableBackup?) {
        onStep?(.creatingCredential)
        var handle = try enrollmentService.enroll(accountId: accountId,
                                                  kind: .portable,
                                                  identity: identity,
                                                  devicePath: devicePath,
                                                  askPIN: askPIN,
                                                  namesakePolicy: .refuse)
        do {
            onStep?(.derivingBackupKey)
            let fixed = try PortableMasterKey.fixedComponent(handle, using: secretDerivationService, pinProvider: askPIN)
            let masterKey = imported?.masterKey ?? CryptoHelpers.randomBytes(count: PortableBackup.masterKeyByteCount)
            handle.account.mask = PortableMasterKey.combine(masterKey, fixed)

            onStep?(.savingRecord)
            try enrollmentService.writeRecord(for: handle, pinProvider: askPIN)
            handle.account.integrity = .ok

            let generated = imported == nil ? PortableBackup(masterKey: masterKey, identity: identity) : nil
            return (handle, generated)
        } catch {
            // A credential without a record is not an account. Best effort: if the key is
            // gone, the credential stays and shows up as incomplete, with Delete as its
            // one action.
            guard KeyFailurePolicy.allowsAuthenticatedRecovery(after: error) else {
                throw KeyMutationError(completed: .credentialCreated, underlying: error)
            }
            do { try enrollmentService.deleteAccount(handle, pin: askPIN?()) }
            catch { throw KeyMutationError(completed: .credentialCreated, underlying: error) }
            throw error
        }
    }

    func exportBackup(_ handle: AccountHandle,
                      pinProvider: (@Sendable () -> String?)?) throws -> PortableBackup {
        guard handle.account.kind == .portable else {
            throw FidoPassError.invalidState("Account is not portable")
        }
        if let problem = handle.account.integrity.problem {
            throw FidoPassError.invalidState(problem)
        }
        let masterKey = try PortableMasterKey.recover(handle, using: secretDerivationService, pinProvider: pinProvider)
        // A v1 account has no identity and yields a backup without one — the 32 bytes
        // earlier versions printed, byte for byte. Export must not wait for migration.
        guard let backup = PortableBackup(masterKey: masterKey, identity: handle.account.identity) else {
            throw FidoPassError.invalidState("Failed to build the backup")
        }
        return backup
    }
}
