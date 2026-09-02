import Foundation
import CryptoKit

final class PasswordGenerator: PasswordGenerating, Sendable {
    private let secretDerivationService: SecretDerivationServiceProtocol

    init(secretDerivationService: SecretDerivationServiceProtocol) {
        self.secretDerivationService = secretDerivationService
    }

    func generatePassword(account: Account,
                          label: String,
                          policy override: PasswordPolicy?,
                          requireUV: Bool,
                          pinProvider: (@Sendable () -> String?)?) throws -> String {
        let policy = override ?? account.policy
        let secret: Data
        if account.kind == .portable {
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
                                 pinProvider: (@Sendable () -> String?)?) throws -> Data {
        guard let payload = account.portable else {
            throw FidoPassError.invalidState("Portable account is missing its key material")
        }
        let fixed = try secretDerivationService.deriveFixedComponent(account: account,
                                                                     requireUV: requireUV,
                                                                     pinProvider: pinProvider)
        guard fixed.count == PortablePayload.externalByteCount else {
            throw FidoPassError.invalidState("Fixed component must be \(PortablePayload.externalByteCount) bytes")
        }
        let imported = Data(zip(fixed, payload.external).map { $0 ^ $1 })
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
