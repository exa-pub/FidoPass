import Foundation
import CLibfido2

final class HmacSecretService: Sendable {
    private let deviceRepository: DeviceAccessing

    init(deviceRepository: DeviceAccessing) {
        self.deviceRepository = deviceRepository
    }

    /// One `hmac-secret` assertion against the account's credential. User verification is
    /// always demanded: a password derived without the PIN would be a password anyone holding
    /// the key could derive.
    func perform(_ handle: AccountHandle,
                 salt: Data,
                 pinProvider: (@Sendable () -> String?)?) throws -> Data {
        try deviceRepository.withOpenedDevice(path: handle.devicePath) { device, _ in
            try deviceRepository.ensureHmacSecretSupported(device)
            guard let assertion = fido_assert_new() else {
                throw FidoPassError.invalidState("assert_new")
            }
            var assert: OpaquePointer? = assertion
            defer { fido_assert_free(&assert) }

            try Libfido2Context.check(fido_assert_set_rp(assertion, handle.account.rpId), operation: "assert_set_rp")

            guard let credentialId = Data(base64Encoded: handle.account.credentialIdB64) else {
                throw FidoPassError.invalidState("Credential ID is not valid base64")
            }
            try credentialId.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_assert_allow_cred(assertion,
                                            pointer.bindMemory(to: UInt8.self).baseAddress,
                                            credentialId.count),
                    operation: "assert_allow_cred")
            }

            try Libfido2Context.check(fido_assert_set_extensions(assertion, Int32(FIDO_EXT_HMAC_SECRET)), operation: "assert_set_extensions(hmac-secret)")
            try salt.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_assert_set_hmac_salt(assertion,
                                               pointer.bindMemory(to: UInt8.self).baseAddress,
                                               salt.count),
                    operation: "assert_set_hmac_salt")
            }

            try Libfido2Context.check(fido_assert_set_up(assertion, FIDO_OPT_TRUE), operation: "assert_set_up")
            try Libfido2Context.check(fido_assert_set_uv(assertion, FIDO_OPT_TRUE), operation: "assert_set_uv")

            let challenge = CryptoHelpers.randomBytes(count: 32)
            try challenge.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_assert_set_clientdata_hash(assertion,
                                                    pointer.bindMemory(to: UInt8.self).baseAddress,
                                                    challenge.count),
                    operation: "assert_set_clientdata_hash")
            }

            try PinScope.withPIN(pinProvider?()) { pinCString in
                try Libfido2Context.check(fido_dev_get_assert(device, assertion, pinCString), operation: "dev_get_assert")
            }

            guard let secretPointer = fido_assert_hmac_secret_ptr(assertion, 0) else {
                throw FidoPassError.invalidState("assert_hmac_secret_ptr=NULL")
            }
            let length = fido_assert_hmac_secret_len(assertion, 0)
            return Data(bytes: secretPointer, count: length)
        }
    }
}
