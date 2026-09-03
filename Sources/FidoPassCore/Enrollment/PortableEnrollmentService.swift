import Foundation

final class PortableEnrollmentService: PortableEnrolling, Sendable {
    private let enrollmentService: Enrolling
    private let secretDerivationService: SecretDeriving

    init(enrollmentService: Enrolling,
         secretDerivationService: SecretDeriving) {
        self.enrollmentService = enrollmentService
        self.secretDerivationService = secretDerivationService
    }

    /// Creates a portable account and returns it together with the freshly generated
    /// backup, if the master key was generated rather than supplied.
    ///
    /// Requires two touches of the authenticator: one for `makeCredential`, one for the
    /// assertion that derives this credential's fixed component. Callers must say so, or
    /// the second prompt looks like the app hanging. The record — kind and mask — is
    /// written last, under the PIN; until it is, the credential is not an account, and a
    /// failure on the way takes the credential back off the key.
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
            try? enrollmentService.deleteAccount(handle, pin: askPIN?())
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
