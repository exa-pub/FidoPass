import Foundation
import CLibfido2

final class EnrollmentService: EnrollmentServiceProtocol {
    /// Marks a portable payload stored in the credential's display-name field.
    ///
    /// CTAP gives a credential two free-form strings (`name`, `displayName`) and portable
    /// accounts need three pieces of information: the account id, a human-readable name
    /// and the exported key material. The prefix keeps the overloaded field
    /// self-describing instead of relying on "base64 that happens to be 32 bytes".
    private static let portablePayloadPrefix = "fp-ext:v1:"

    private let deviceRepository: DeviceRepositoryProtocol

    init(deviceRepository: DeviceRepositoryProtocol) {
        self.deviceRepository = deviceRepository
    }

    func enroll(accountId: String,
                kind: AccountKind,
                displayName: String,
                requireUV: Bool,
                devicePath: String?,
                askPIN: (() -> String?)?) throws -> Account {
        let trimmedId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw FidoPassError.invalidState("Account ID must not be empty")
        }

        // Reject duplicates before writing anything. Two credentials sharing an account id
        // on one authenticator are indistinguishable in the UI and permanently occupy a
        // resident-key slot each. Enumeration needs no user presence, so this costs one
        // silent round-trip. It runs before the device is opened for makeCredential —
        // nesting two opens on the same device would fail.
        if let path = devicePath {
            let existing = try enumerateAccounts(rpId: kind.rpId, devicePath: path, pin: askPIN?())
            if existing.contains(where: { $0.id == trimmedId }) {
                throw FidoPassError.invalidState("An account named ‘\(trimmedId)’ already exists on this device")
            }
        }

        return try deviceRepository.withOpenedDevice(path: devicePath) { device, path in
            try deviceRepository.ensureHmacSecretSupported(device)
            guard let credential = fido_cred_new() else {
                throw FidoPassError.invalidState("cred_new")
            }
            var cred: OpaquePointer? = credential
            defer { fido_cred_free(&cred) }

            try Libfido2Context.check(fido_cred_set_type(credential, COSE_ES256), operation: "cred_set_type")
            try Libfido2Context.check(fido_cred_set_extensions(credential, Int32(FIDO_EXT_HMAC_SECRET)), operation: "cred_set_extensions(hmac-secret)")
            try Libfido2Context.check(fido_cred_set_rp(credential, kind.rpId, "FidoPass"), operation: "cred_set_rp")

            let packedId = try Self.encodeUserId(trimmedId)
            try packedId.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_user(credential,
                                        pointer.bindMemory(to: UInt8.self).baseAddress,
                                        packedId.count,
                                        Self.credentialName(accountId: trimmedId),
                                        Self.credentialDisplayName(kind: kind,
                                                                   accountId: trimmedId,
                                                                   displayName: displayName,
                                                                   portable: nil),
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

            try PinScope.withPIN(requireUV ? askPIN?() : nil) { pinCString in
                try Libfido2Context.check(fido_dev_make_cred(device, credential, pinCString), operation: "dev_make_cred")
            }

            guard let idPointer = fido_cred_id_ptr(credential) else {
                throw FidoPassError.invalidState("cred_id_ptr")
            }
            let credentialId = Data(bytes: idPointer, count: fido_cred_id_len(credential))

            return Account(id: trimmedId,
                           kind: kind,
                           displayName: displayName,
                           credentialIdB64: credentialId.base64EncodedString(),
                           revision: 1,
                           policy: PasswordPolicy(),
                           devicePath: path,
                           portable: nil)
        }
    }

    func enumerateAccounts(rpId: String,
                           devicePath: String,
                           pin: String?) throws -> [Account] {
        guard let kind = AccountKind(rpId: rpId) else {
            throw FidoPassError.invalidState("Unknown relying-party id ‘\(rpId)’")
        }

        return try deviceRepository.withOpenedDevice(path: devicePath) { device, path in
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

            let rc = PinScope.withPIN(pin) { fido_dev_get_assert(device, assertion, $0) }
            if rc == FIDO_ERR_NO_CREDENTIALS { return [] }
            try Libfido2Context.check(rc, operation: "dev_get_assert(enumerate)")

            let count = Int(fido_assert_count(assertion))
            var accounts: [Account] = []
            accounts.reserveCapacity(count)

            for index in 0..<count {
                guard let credentialPointer = fido_assert_id_ptr(assertion, index),
                      let userIdPointer = fido_assert_user_id_ptr(assertion, index) else { continue }
                let credential = Data(bytes: credentialPointer, count: fido_assert_id_len(assertion, index))
                let userId = Data(bytes: userIdPointer, count: fido_assert_user_id_len(assertion, index))
                guard let accountId = String(data: userId, encoding: .utf8) else { continue }

                let rawDisplayName = fido_assert_user_display_name(assertion, index).map { String(cString: $0) } ?? ""
                let rawName = fido_assert_user_name(assertion, index).map { String(cString: $0) } ?? ""

                let decoded = Self.decodeUserFields(kind: kind, name: rawName, displayName: rawDisplayName)

                accounts.append(Account(id: accountId,
                                        kind: kind,
                                        displayName: decoded.displayName,
                                        credentialIdB64: credential.base64EncodedString(),
                                        revision: 1,
                                        policy: PasswordPolicy(),
                                        devicePath: path,
                                        portable: decoded.portable))
            }
            return accounts
        }
    }

    func deleteAccount(_ account: Account, pin: String?) throws {
        guard let credId = Data(base64Encoded: account.credentialIdB64) else {
            throw FidoPassError.invalidState("Credential ID is not valid base64")
        }
        try deviceRepository.withOpenedDevice(path: account.devicePath) { device, _ in
            let rc = PinScope.withPIN(pin) { pinCString in
                credId.withUnsafeBytes { pointer -> Int32 in
                    fido_credman_del_dev_rk(device,
                                            pointer.bindMemory(to: UInt8.self).baseAddress,
                                            credId.count,
                                            pinCString)
                }
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

    func updateCredentialUserInfo(account: Account,
                                  requireUV: Bool,
                                  pinProvider: (() -> String?)?) throws {
        guard let credentialId = Data(base64Encoded: account.credentialIdB64) else {
            throw FidoPassError.invalidState("Credential ID is not valid base64")
        }
        try deviceRepository.withOpenedDevice(path: account.devicePath) { device, _ in
            guard let residentCredential = fido_cred_new() else {
                throw FidoPassError.invalidState("cred_new")
            }
            var cred: OpaquePointer? = residentCredential
            defer { fido_cred_free(&cred) }

            try Libfido2Context.check(fido_cred_set_rp(residentCredential, account.rpId, "FidoPass"), operation: "cred_set_rp(update)")
            try credentialId.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_id(residentCredential,
                                      pointer.bindMemory(to: UInt8.self).baseAddress,
                                      credentialId.count),
                    operation: "cred_set_id")
            }

            let packedId = try Self.encodeUserId(account.id)
            try packedId.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_user(residentCredential,
                                        pointer.bindMemory(to: UInt8.self).baseAddress,
                                        packedId.count,
                                        Self.credentialName(accountId: account.id),
                                        Self.credentialDisplayName(kind: account.kind,
                                                                   accountId: account.id,
                                                                   displayName: account.displayName,
                                                                   portable: account.portable),
                                        nil),
                    operation: "cred_set_user(update)")
            }
            try Libfido2Context.check(fido_cred_set_type(residentCredential, COSE_ES256), operation: "cred_set_type(update)")

            // The result used to be discarded, so a rejected write looked like success and
            // the change silently vanished on the next reload.
            try PinScope.withPIN(requireUV ? pinProvider?() : nil) { pinCString in
                try Libfido2Context.check(fido_credman_set_dev_rk(device, residentCredential, pinCString),
                                          operation: "credman_set_dev_rk")
            }
        }
    }

    // MARK: - Credential user fields

    /// Machine identifier. Always the account id, for every kind.
    private static func credentialName(accountId: String) -> String {
        String(accountId.prefix(32))
    }

    /// Never returns an empty string.
    ///
    /// An empty display name makes `fido_dev_make_cred` fail with
    /// `FIDO_ERR_INVALID_LENGTH` before the request even reaches the authenticator, so
    /// enrolment dies instantly with an error that names no cause. Accounts are routinely
    /// created without a display name, so the account id is the fallback.
    static func credentialDisplayNameForTesting(kind: AccountKind,
                                                accountId: String,
                                                displayName: String,
                                                portable: PortablePayload?) -> String {
        credentialDisplayName(kind: kind, accountId: accountId, displayName: displayName, portable: portable)
    }

    private static func credentialDisplayName(kind: AccountKind,
                                              accountId: String,
                                              displayName: String,
                                              portable: PortablePayload?) -> String {
        switch kind {
        case .local:
            return displayName.isEmpty ? accountId : displayName
        case .portable:
            guard let portable else { return displayName.isEmpty ? accountId : displayName }
            return portablePayloadPrefix + portable.base64
        }
    }

    /// Reads the two credential strings back, accepting both the current layout and the
    /// one written before the fields were disentangled.
    ///
    /// The pre-existing layout put the raw payload in `name` and the account id in
    /// `displayName`. Accounts enrolled that way are still on users' keys and must keep
    /// working — losing the payload would make their passwords unreproducible.
    static func decodeUserFields(kind: AccountKind,
                                         name: String,
                                         displayName: String) -> (displayName: String, portable: PortablePayload?) {
        guard kind == .portable else {
            return (displayName, nil)
        }
        if displayName.hasPrefix(portablePayloadPrefix) {
            let encoded = String(displayName.dropFirst(portablePayloadPrefix.count))
            return ("", PortablePayload(base64: encoded))
        }
        if let legacy = PortablePayload(base64: name) {
            return ("", legacy)
        }
        return (displayName, nil)
    }

    private static func encodeUserId(_ accountId: String) throws -> Data {
        let data = Data(accountId.utf8)
        if data.isEmpty || data.count > 64 {
            throw FidoPassError.invalidState("Account ID must be 1–64 bytes when UTF-8 encoded")
        }
        return data
    }
}
