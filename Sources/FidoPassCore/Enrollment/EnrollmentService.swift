import Foundation
import CLibfido2

final class EnrollmentService: EnrollmentServiceProtocol {
    private let deviceRepository: DeviceRepositoryProtocol

    init(deviceRepository: DeviceRepositoryProtocol) {
        self.deviceRepository = deviceRepository
    }

    func enroll(accountId: String,
                rpId: String,
                userName: String,
                requireUV: Bool,
                residentKey: Bool,
                devicePath: String?,
                askPIN: (() -> String?)?) throws -> Account {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, path in
            try deviceRepository.ensureHmacSecretSupported(device)
            guard residentKey else {
                throw FidoPassError.invalidState("Non-resident credentials are not supported without local storage")
            }
            guard let credential = fido_cred_new() else {
                throw FidoPassError.invalidState("cred_new")
            }
            var cred: OpaquePointer? = credential
            defer { fido_cred_free(&cred) }

            try Libfido2Context.check(fido_cred_set_type(credential, COSE_ES256), operation: "cred_set_type")
            try Libfido2Context.check(fido_cred_set_extensions(credential, Int32(FIDO_EXT_HMAC_SECRET)), operation: "cred_set_extensions(hmac-secret)")
            try Libfido2Context.check(fido_cred_set_rp(credential, rpId, "FidoPass"), operation: "cred_set_rp")

            let packedId = try encodeUserId(accountId)
            let shortName = String(accountId.prefix(32))
            let displayName = userName.isEmpty ? accountId : userName
            try packedId.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_user(credential,
                                        pointer.bindMemory(to: UInt8.self).baseAddress,
                                        packedId.count,
                                        shortName,
                                        displayName,
                                        nil),
                    operation: "cred_set_user")
            }

            try Libfido2Context.check(fido_cred_set_rk(credential, FIDO_OPT_TRUE), operation: "cred_set_rk")
            try Libfido2Context.check(fido_cred_set_uv(credential, requireUV ? FIDO_OPT_TRUE : FIDO_OPT_OMIT), operation: "cred_set_uv")

            let challenge = CryptoHelpers.randomBytes(count: 32)
            try challenge.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_clientdata_hash(credential,
                                                  pointer.bindMemory(to: UInt8.self).baseAddress,
                                                  challenge.count),
                    operation: "cred_set_clientdata_hash")
            }

            var pinCString: UnsafePointer<CChar>? = nil
            if requireUV, let pin = askPIN?() {
                pinCString = UnsafePointer(strdup(pin))
            }
            defer {
                if let pinCString {
                    free(UnsafeMutableRawPointer(mutating: pinCString))
                }
            }

            try Libfido2Context.check(fido_dev_make_cred(device, credential, pinCString), operation: "dev_make_cred")

            guard let idPointer = fido_cred_id_ptr(credential) else {
                throw FidoPassError.invalidState("cred_id_ptr")
            }
            let length = fido_cred_id_len(credential)
            let credentialId = Data(bytes: idPointer, count: length)

            return Account(id: accountId,
                           rpId: rpId,
                           userName: userName,
                           credentialIdB64: credentialId.base64EncodedString(),
                           revision: 1,
                           policy: PasswordPolicy(),
                           devicePath: path)
        }
    }

    func enumerateAccounts(rpId: String,
                           devicePath: String,
                           pin: String?) throws -> [Account] {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, path in
            guard let assertion = fido_assert_new() else {
                throw FidoPassError.invalidState("assert_new")
            }
            var assert: OpaquePointer? = assertion
            defer { fido_assert_free(&assert) }

            try Libfido2Context.check(fido_assert_set_rp(assertion, rpId), operation: "assert_set_rp")
            let challenge = CryptoHelpers.randomBytes(count: 32)
            try challenge.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_assert_set_clientdata_hash(assertion,
                                                    pointer.bindMemory(to: UInt8.self).baseAddress,
                                                    challenge.count),
                    operation: "assert_set_clientdata_hash")
            }
            try Libfido2Context.check(fido_assert_set_up(assertion, FIDO_OPT_FALSE), operation: "assert_set_up")

            if pin != nil {
                _ = fido_assert_set_uv(assertion, FIDO_OPT_TRUE)
            }

            var pinCString: UnsafePointer<CChar>? = nil
            if let pin {
                pinCString = UnsafePointer(strdup(pin))
            }
            defer {
                if let pinCString {
                    free(UnsafeMutableRawPointer(mutating: pinCString))
                }
            }

            let rc = fido_dev_get_assert(device, assertion, pinCString)
            if rc == FIDO_ERR_NO_CREDENTIALS { return [] }
            try Libfido2Context.check(rc, operation: "dev_get_assert(enumerate)")

            let count = Int(fido_assert_count(assertion))
            var accounts: [Account] = []
            accounts.reserveCapacity(count)

            for index in 0..<count {
                guard let credentialPointer = fido_assert_id_ptr(assertion, index) else { continue }
                let length = fido_assert_id_len(assertion, index)
                let credential = Data(bytes: credentialPointer, count: length)

                let displayName = fido_assert_user_display_name(assertion, index).map { String(cString: $0) } ?? ""
                let userNamePtr = fido_assert_user_name(assertion, index)
                let accountId: String
                if let userIdPointer = fido_assert_user_id_ptr(assertion, index) {
                    let userIdLength = fido_assert_user_id_len(assertion, index)
                    let data = Data(bytes: userIdPointer, count: userIdLength)
                    guard let decoded = decodeUserId(data) else { continue }
                    accountId = decoded
                } else {
                    continue
                }

                var finalUserName = displayName
                if rpId == "fidopass.portable", let userNamePtr {
                    let candidate = String(cString: userNamePtr)
                    if let data = Data(base64Encoded: candidate), data.count == 32 {
                        finalUserName = candidate
                    }
                }

                accounts.append(Account(id: accountId,
                                         rpId: rpId,
                                         userName: finalUserName,
                                         credentialIdB64: credential.base64EncodedString(),
                                         revision: 1,
                                         policy: PasswordPolicy(),
                                         devicePath: path))
            }
            return accounts
        }
    }

    func deleteAccount(_ account: Account, pin: String?) throws {
        guard let credId = Data(base64Encoded: account.credentialIdB64) else {
            throw FidoPassError.invalidState("Credential ID is not valid base64")
        }
        try deviceRepository.withOpenedDevice(path: account.devicePath) { device, _ in
            var pinCString: UnsafePointer<CChar>? = nil
            if let pin {
                pinCString = UnsafePointer(strdup(pin))
            }
            defer {
                if let pinCString {
                    free(UnsafeMutableRawPointer(mutating: pinCString))
                }
            }

            let rc = credId.withUnsafeBytes { pointer -> Int32 in
                fido_credman_del_dev_rk(device,
                                        pointer.bindMemory(to: UInt8.self).baseAddress,
                                        credId.count,
                                        pinCString)
            }
            if rc == FIDO_ERR_INVALID_COMMAND {
                throw FidoPassError.unsupported("Credential Management is not supported by the device")
            }
            if rc == FIDO_ERR_PIN_REQUIRED {
                throw FidoPassError.invalidState("PIN is required for deletion")
            }
            try Libfido2Context.check(rc, operation: "credman_del")
        }
    }

    func updateCredentialUserName(account: Account,
                                  newUserName: String,
                                  requireUV: Bool,
                                  pinProvider: (() -> String?)?) throws {
        guard let credentialId = Data(base64Encoded: account.credentialIdB64) else { return }
        try deviceRepository.withOpenedDevice(path: account.devicePath) { device, _ in
            guard let residentCredential = fido_cred_new() else {
                throw FidoPassError.invalidState("cred_new")
            }
            defer {
                var cred: OpaquePointer? = residentCredential
                fido_cred_free(&cred)
            }

            try Libfido2Context.check(fido_cred_set_rp(residentCredential, account.rpId, "FidoPass"), operation: "cred_set_rp(update)")
            try credentialId.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_id(residentCredential,
                                      pointer.bindMemory(to: UInt8.self).baseAddress,
                                      credentialId.count),
                    operation: "cred_set_id")
            }

            let metadata = (try? encodeUserId(account.id)) ?? Data()
            try metadata.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_user(residentCredential,
                                        pointer.bindMemory(to: UInt8.self).baseAddress,
                                        metadata.count,
                                        newUserName,
                                        account.id,
                                        nil),
                    operation: "cred_set_user(update)")
            }
            try Libfido2Context.check(fido_cred_set_type(residentCredential, COSE_ES256), operation: "cred_set_type(update)")

            var pinCString: UnsafePointer<CChar>? = nil
            if requireUV, let pin = pinProvider?() {
                pinCString = UnsafePointer(strdup(pin))
            }
            defer {
                if let pinCString {
                    free(UnsafeMutableRawPointer(mutating: pinCString))
                }
            }
            _ = fido_credman_set_dev_rk(device, residentCredential, pinCString)
        }
    }

    private func encodeUserId(_ accountId: String) throws -> Data {
        let data = Data(accountId.utf8)
        if data.isEmpty || data.count > 64 {
            throw FidoPassError.invalidState("accountId length invalid")
        }
        return data
    }

    private func decodeUserId(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }
}
