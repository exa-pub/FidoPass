import Foundation
import CryptoKit

final class PasswordGenerator: PasswordGenerating {
    private let secretDerivationService: SecretDerivationServiceProtocol

    init(secretDerivationService: SecretDerivationServiceProtocol) {
        self.secretDerivationService = secretDerivationService
    }

    func generatePassword(account: Account,
                          label: String,
                          policy override: PasswordPolicy?,
                          requireUV: Bool,
                          pinProvider: (() -> String?)?) throws -> String {
        let policy = override ?? account.policy
        let secret: Data
        if account.rpId == "fidopass.portable" {
            secret = try portableSecret(account: account,
                                        label: label,
                                        requireUV: requireUV,
                                        pinProvider: pinProvider)
        } else {
            secret = try secretDerivationService.deriveSecret(account: account,
                                                              label: label,
                                                              requireUV: requireUV,
                                                              pinProvider: pinProvider)
        }

        let material = deriveMaterial(from: secret, policy: policy)
        return PasswordEngine.mapToPassword(material, policy: policy)
    }

    private func portableSecret(account: Account,
                                 label: String,
                                 requireUV: Bool,
                                 pinProvider: (() -> String?)?) throws -> Data {
        guard let external = Data(base64Encoded: account.userName), external.count == 32 else {
            throw FidoPassError.invalidState("Portable userName must contain base64 External (32 bytes)")
        }
        let fixed = try secretDerivationService.deriveFixedComponent(account: account,
                                                                     requireUV: requireUV,
                                                                     pinProvider: pinProvider)
        guard fixed.count == 32 else {
            throw FidoPassError.invalidState("Fixed component size !=32")
        }
        let imported = Data(zip(fixed, external).map { $0 ^ $1 })
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
