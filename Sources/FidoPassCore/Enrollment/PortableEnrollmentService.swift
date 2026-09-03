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
    /// assertion that derives this device's fixed component. Callers must say so, or the
    /// second prompt looks like the app hanging.
    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: (@Sendable () -> String?)?,
                        imported: PortableBackup?,
                        onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (AccountHandle, PortableBackup?) {
        onStep?(.creatingCredential)
        var handle = try enrollmentService.enroll(accountId: accountId,
                                                  kind: .portable,
                                                  devicePath: devicePath,
                                                  askPIN: askPIN)

        onStep?(.derivingBackupKey)
        let fixed = try PortableMasterKey.fixedComponent(handle, using: secretDerivationService, pinProvider: askPIN)

        let masterKey = imported?.masterKey ?? CryptoHelpers.randomBytes(count: PortableBackup.masterKeyByteCount)
        // The payload written is always the current layout. A fresh account gets a random
        // identity, an import keeps the one it came with, and a backup from before identities
        // — the panel asks for one before it gets here — falls back to a random one rather
        // than to a payload that would need migrating the moment it was created.
        let identity = imported?.identity ?? .random()

        guard let payload = PortablePayload(external: PortableMasterKey.combine(masterKey, fixed),
                                            identity: identity) else {
            throw FidoPassError.invalidState("Failed to build portable payload")
        }
        handle.account.portable = payload

        onStep?(.savingPayload)
        try enrollmentService.updateCredentialUserInfo(handle, pinProvider: askPIN)

        let generated = imported == nil ? PortableBackup(masterKey: masterKey, identity: identity) : nil
        return (handle, generated)
    }

    func exportBackup(_ handle: AccountHandle,
                      pinProvider: (@Sendable () -> String?)?) throws -> PortableBackup {
        let payload = try portablePayload(of: handle)
        let masterKey = try PortableMasterKey.recover(handle, using: secretDerivationService, pinProvider: pinProvider)
        // A payload without an identity yields a backup without one — the 32 bytes earlier
        // versions printed, byte for byte. Migration is what adds the identity, and it is
        // the user's to do; export must not depend on it.
        guard let backup = PortableBackup(masterKey: masterKey, identity: payload.identity) else {
            throw FidoPassError.invalidState("Failed to build the backup")
        }
        return backup
    }

    func assignIdentity(_ handle: AccountHandle,
                        identity: AccountIdentity,
                        pinProvider: (@Sendable () -> String?)?) throws -> AccountHandle {
        let payload = try portablePayload(of: handle)
        guard payload.needsMigration else {
            throw FidoPassError.invalidState("Account ‘\(handle.id)’ already has an identity")
        }
        var updated = handle
        // Same external, so the same master key and the same passwords. Only the name field
        // on the key changes, and `updateCredentialUserInfo` needs the PIN, not a touch.
        updated.account.portable = PortablePayload(external: payload.external, identity: identity)
        try enrollmentService.updateCredentialUserInfo(updated, pinProvider: pinProvider)
        return updated
    }

    // MARK: - Helpers

    private func portablePayload(of handle: AccountHandle) throws -> PortablePayload {
        guard handle.account.kind == .portable else {
            throw FidoPassError.invalidState("Account is not portable")
        }
        guard let payload = handle.account.portable else {
            throw FidoPassError.invalidState("Portable account is missing its key material")
        }
        return payload
    }
}
