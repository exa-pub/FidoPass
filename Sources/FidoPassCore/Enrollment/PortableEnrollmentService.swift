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
    /// master key, if one was generated rather than supplied.
    ///
    /// Requires two touches of the authenticator: one for `makeCredential`, one for the
    /// assertion that derives this device's fixed component. Callers must say so, or the
    /// second prompt looks like the app hanging.
    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: (@Sendable () -> String?)?,
                        importedKeyB64: String?,
                        onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (AccountHandle, String?) {
        onStep?(.creatingCredential)
        var handle = try enrollmentService.enroll(accountId: accountId,
                                                  kind: .portable,
                                                  devicePath: devicePath,
                                                  askPIN: askPIN)

        onStep?(.derivingBackupKey)
        let fixed = try secretDerivationService.deriveFixedComponent(handle, pinProvider: askPIN)
        guard fixed.count == PortablePayload.externalByteCount else {
            throw FidoPassError.invalidState("Fixed component must be \(PortablePayload.externalByteCount) bytes")
        }

        let importedKey: Data
        if let importedKeyB64 {
            guard let data = Data(base64Encoded: importedKeyB64),
                  data.count == PortablePayload.externalByteCount else {
                throw FidoPassError.invalidState("Imported key must be \(PortablePayload.externalByteCount) base64-encoded bytes")
            }
            importedKey = data
        } else {
            importedKey = CryptoHelpers.randomBytes(count: PortablePayload.externalByteCount)
        }

        guard let payload = PortablePayload(external: Data(zip(importedKey, fixed).map { $0 ^ $1 })) else {
            throw FidoPassError.invalidState("Failed to build portable payload")
        }
        handle.account.portable = payload

        onStep?(.savingPayload)
        try enrollmentService.updateCredentialUserInfo(handle, pinProvider: askPIN)

        return (handle, importedKeyB64 == nil ? importedKey.base64EncodedString() : nil)
    }

    func exportImportedKey(_ handle: AccountHandle,
                           pinProvider: (@Sendable () -> String?)?) throws -> String {
        guard handle.account.kind == .portable else {
            throw FidoPassError.invalidState("Account is not portable")
        }
        guard let payload = handle.account.portable else {
            throw FidoPassError.invalidState("Portable account is missing its key material")
        }
        let fixed = try secretDerivationService.deriveFixedComponent(handle, pinProvider: pinProvider)
        guard fixed.count == PortablePayload.externalByteCount else {
            throw FidoPassError.invalidState("Fixed component must be \(PortablePayload.externalByteCount) bytes")
        }
        return Data(zip(fixed, payload.external).map { $0 ^ $1 }).base64EncodedString()
    }
}
