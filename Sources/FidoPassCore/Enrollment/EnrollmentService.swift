import Foundation
import CLibfido2

final class EnrollmentService: Enrolling, Sendable {
    /// Marks a portable payload stored in the credential's display-name field.
    ///
    /// CTAP gives a credential two free-form strings (`name`, `displayName`) and portable
    /// accounts need three pieces of information: the account id, a human-readable name
    /// and the exported key material. The prefix keeps the overloaded field
    /// self-describing instead of relying on "base64 that happens to be 32 bytes".
    private static let portablePayloadPrefix = "fp-ext:v1:"

    private let deviceRepository: DeviceAccessing

    init(deviceRepository: DeviceAccessing) {
        self.deviceRepository = deviceRepository
    }

    func enroll(accountId: String,
                kind: AccountKind,
                displayName: String,
                requireUV: Bool,
                devicePath: String,
                askPIN: (@Sendable () -> String?)?) throws -> Account {
        let trimmedId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw FidoPassError.invalidState("Account ID must not be empty")
        }

        // Reject duplicates before writing anything. Two credentials sharing an account id
        // on one authenticator are indistinguishable in the UI and permanently occupy a
        // resident-key slot each. Enumeration needs no user presence, so this costs one
        // silent round-trip. It runs before the device is opened for makeCredential —
        // nesting two opens on the same device would fail.
        if let pin = askPIN?(), !pin.isEmpty {
            // Best-effort: a key that cannot list its credentials still deserves to be
            // enrolled, so a failure to check is not a failure to create.
            let existing = (try? enumerateAccounts(rpId: kind.rpId, devicePath: devicePath, pin: pin)) ?? []
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
                                        Self.credentialName(kind: kind, accountId: trimmedId, portable: nil),
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

    /// Reads the accounts stored on an authenticator.
    ///
    /// Uses credential management rather than a silent assertion. An assertion made with
    /// `up = false` returns only `user.id`: CTAP withholds `name` and `displayName` unless
    /// user presence is confirmed, so the portable payload — which lives in `displayName` —
    /// came back empty and portable accounts lost their key material on every reload.
    /// Credential management returns the full user entity and still needs no touch, only
    /// the PIN.
    func enumerateAccounts(rpId: String,
                           devicePath: String,
                           pin: String?) throws -> [Account] {
        guard let kind = AccountKind(rpId: rpId) else {
            throw FidoPassError.invalidState("Unknown relying-party id ‘\(rpId)’")
        }
        guard let pin, !pin.isEmpty else {
            throw FidoPassError.invalidState("A PIN is required to list accounts on the key")
        }

        return try deviceRepository.withOpenedDevice(path: devicePath) { device, path in
            guard let rawList = fido_credman_rk_new() else {
                throw FidoPassError.invalidState("credman_rk_new")
            }
            var residentKeys: OpaquePointer? = rawList
            defer { fido_credman_rk_free(&residentKeys) }

            let rc = PinScope.withPIN(pin) { fido_credman_get_dev_rk(device, rpId, rawList, $0) }
            // An authenticator with nothing stored for this relying party reports it as an
            // error rather than an empty list.
            if rc == FIDO_ERR_NO_CREDENTIALS { return [] }
            try Libfido2Context.checkCredman(rc, operation: "credman_get_dev_rk")

            let count = fido_credman_rk_count(rawList)
            var accounts: [Account] = []
            accounts.reserveCapacity(count)

            for index in 0..<count {
                guard let credential = fido_credman_rk(rawList, index),
                      let credentialPointer = fido_cred_id_ptr(credential),
                      let userIdPointer = fido_cred_user_id_ptr(credential) else { continue }

                let credentialId = Data(bytes: credentialPointer, count: fido_cred_id_len(credential))
                let userId = Data(bytes: userIdPointer, count: fido_cred_user_id_len(credential))
                guard let accountId = String(data: userId, encoding: .utf8) else { continue }

                let rawName = fido_cred_user_name(credential).map { String(cString: $0) } ?? ""
                let rawDisplayName = fido_cred_display_name(credential).map { String(cString: $0) } ?? ""
                let decoded = Self.decodeUserFields(kind: kind, name: rawName, displayName: rawDisplayName)

                accounts.append(Account(id: accountId,
                                        kind: kind,
                                        displayName: decoded.displayName,
                                        credentialIdB64: credentialId.base64EncodedString(),
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
        guard let devicePath = account.devicePath else {
            throw FidoPassError.invalidState("The account is not attached to a connected key")
        }
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            let rc = PinScope.withPIN(pin) { pinCString in
                credId.withUnsafeBytes { pointer -> Int32 in
                    fido_credman_del_dev_rk(device,
                                            pointer.bindMemory(to: UInt8.self).baseAddress,
                                            credId.count,
                                            pinCString)
                }
            }
            if rc == FIDO_ERR_PIN_REQUIRED {
                throw FidoPassError.invalidState("PIN is required for deletion")
            }
            try Libfido2Context.checkCredman(rc, operation: "credman_del")
        }
    }

    func updateCredentialUserInfo(account: Account,
                                  requireUV: Bool,
                                  pinProvider: (@Sendable () -> String?)?) throws {
        guard let credentialId = Data(base64Encoded: account.credentialIdB64) else {
            throw FidoPassError.invalidState("Credential ID is not valid base64")
        }
        guard let devicePath = account.devicePath else {
            throw FidoPassError.invalidState("The account is not attached to a connected key")
        }
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
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
                                        Self.credentialName(kind: account.kind,
                                                            accountId: account.id,
                                                            portable: account.portable),
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

    /// Value written to the credential's `name` field.
    ///
    /// For a portable account this carries the key material, because that is where every
    /// released version of FidoPass looks for it. Moving it elsewhere made accounts created
    /// by this build unreadable by earlier ones, which failed with
    /// "Portable userName must contain base64 External (32 bytes)".
    static func credentialName(kind: AccountKind,
                                       accountId: String,
                                       portable: PortablePayload?) -> String {
        if kind == .portable, let portable {
            return portable.base64
        }
        return String(accountId.prefix(32))
    }


    /// Value written to the credential's `displayName` field. Never empty.
    ///
    /// An empty display name makes `fido_dev_make_cred` fail with `FIDO_ERR_INVALID_LENGTH`
    /// before the request even reaches the authenticator, so enrolment dies instantly with
    /// an error that names no cause. Accounts are routinely created without a display name,
    /// so the account id is the fallback.
    ///
    /// A portable account has no room for a human-readable name: its `name` field is taken
    /// by the key material, so the account id goes here — the layout earlier versions write
    /// and expect.
    static func credentialDisplayName(kind: AccountKind,
                                              accountId: String,
                                              displayName: String,
                                              portable: PortablePayload?) -> String {
        if kind == .portable, portable != nil {
            return accountId
        }
        return displayName.isEmpty ? accountId : displayName
    }

    /// Reads the two credential strings back.
    ///
    /// The written layout puts a portable payload in `name`, which is what every released
    /// version reads. The prefixed `displayName` form is still accepted because builds
    /// between the refactor and this fix wrote it, and those accounts are on real keys —
    /// losing the payload would make their passwords unreproducible.
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
