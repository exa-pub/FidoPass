import Foundation

final class PortableEnrollmentService: PortableEnrollmentServiceProtocol {
    private let enrollmentService: EnrollmentServiceProtocol
    private let secretDerivationService: SecretDerivationServiceProtocol

    init(enrollmentService: EnrollmentServiceProtocol,
         secretDerivationService: SecretDerivationServiceProtocol) {
        self.enrollmentService = enrollmentService
        self.secretDerivationService = secretDerivationService
    }

    func enrollPortable(accountId: String,
                        requireUV: Bool,
                        devicePath: String?,
                        askPIN: (() -> String?)?,
                        importedKeyB64: String?) throws -> (Account, String?) {
        let rpId = "fidopass.portable"
        var account = try enrollmentService.enroll(accountId: accountId,
                                                   rpId: rpId,
                                                   userName: "",
                                                   requireUV: requireUV,
                                                   residentKey: true,
                                                   devicePath: devicePath,
                                                   askPIN: askPIN)

        let fixed = try secretDerivationService.deriveFixedComponent(account: account,
                                                                     requireUV: requireUV,
                                                                     pinProvider: askPIN)
        guard fixed.count == 32 else {
            throw FidoPassError.invalidState("Fixed component size !=32")
        }

        let importedKey: Data
        if let importedKeyB64 {
            guard let data = Data(base64Encoded: importedKeyB64), data.count == 32 else {
                throw FidoPassError.invalidState("ImportedKey base64 must be 32 bytes")
            }
            importedKey = data
        } else {
            importedKey = CryptoHelpers.randomBytes(count: 32)
        }

        let external = Data(zip(importedKey, fixed).map { $0 ^ $1 })
        account.userName = external.base64EncodedString()

        try enrollmentService.updateCredentialUserName(account: account,
                                                       newUserName: account.userName,
                                                       requireUV: requireUV,
                                                       pinProvider: askPIN)

        let generated = importedKeyB64 == nil ? importedKey.base64EncodedString() : nil
        return (account, generated)
    }

    func exportImportedKey(_ account: Account,
                           requireUV: Bool,
                           pinProvider: (() -> String?)?) throws -> String {
        guard account.rpId == "fidopass.portable" else {
            throw FidoPassError.invalidState("Account is not portable")
        }
        guard let external = Data(base64Encoded: account.userName), external.count == 32 else {
            throw FidoPassError.invalidState("userName does not contain a valid external base64 payload")
        }
        let fixed = try secretDerivationService.deriveFixedComponent(account: account,
                                                                     requireUV: requireUV,
                                                                     pinProvider: pinProvider)
        guard fixed.count == 32 else {
            throw FidoPassError.invalidState("Fixed component size !=32")
        }
        let imported = Data(zip(fixed, external).map { $0 ^ $1 })
        return imported.base64EncodedString()
    }
}
