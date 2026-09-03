import Foundation
import CryptoKit

final class PasswordGenerator: PasswordGenerating, Sendable {
    private let secretDerivationService: SecretDeriving

    init(secretDerivationService: SecretDeriving) {
        self.secretDerivationService = secretDerivationService
    }

    func generatePassword(_ handle: AccountHandle,
                          label: String,
                          parameters: DerivationParameters,
                          pinProvider: (@Sendable () -> String?)?) throws -> String {
        let secret: Data
        if handle.account.kind == .portable {
            secret = try portableSecret(handle, label: label, pinProvider: pinProvider)
        } else {
            secret = try secretDerivationService.deriveSecret(handle,
                                                              label: label,
                                                              revision: parameters.revision,
                                                              pinProvider: pinProvider)
        }

        let material = deriveMaterial(from: secret, policy: parameters.policy)
        return PasswordEngine.mapToPassword(material, policy: parameters.policy)
    }

    private func portableSecret(_ handle: AccountHandle,
                                label: String,
                                pinProvider: (@Sendable () -> String?)?) throws -> Data {
        let imported = try PortableMasterKey.recover(handle, using: secretDerivationService, pinProvider: pinProvider)
        let salt = SaltFactory.portableLabelSalt(label)
        let mac = HMAC<SHA256>.authenticationCode(for: salt, using: SymmetricKey(data: imported))
        return Data(mac)
    }

    private func deriveMaterial(from secret: Data, policy: PasswordPolicy) -> Data {
        let key = SymmetricKey(data: secret)
        let info = Data("fidopass|pw|v\(policy.version)".utf8)
        let salt = Data("pw-map".utf8)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key,
                                             salt: salt,
                                             info: info,
                                             outputByteCount: max(64, policy.length * 3))
        return Data(derived.withUnsafeBytes { Data($0) })
    }
}
