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
                devicePath: String,
                askPIN: (@Sendable () -> String?)?) throws -> AccountHandle {
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
                                        Self.credentialDisplayName(accountId: trimmedId),
                                        nil),
                    operation: "cred_set_user")
            }

            try Libfido2Context.check(fido_cred_set_rk(credential, FIDO_OPT_TRUE), operation: "cred_set_rk")
            try Libfido2Context.check(fido_cred_set_uv(credential, FIDO_OPT_TRUE), operation: "cred_set_uv")

            let challenge = CryptoHelpers.randomBytes(count: 32)
            try challenge.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_clientdata_hash(credential,
                                                  pointer.bindMemory(to: UInt8.self).baseAddress,
                                                  challenge.count),
                    operation: "cred_set_clientdata_hash")
            }

            try PinScope.withPIN(askPIN?()) { pinCString in
                try Libfido2Context.check(fido_dev_make_cred(device, credential, pinCString), operation: "dev_make_cred")
            }

            guard let idPointer = fido_cred_id_ptr(credential) else {
                throw FidoPassError.invalidState("cred_id_ptr")
            }
            let credentialId = Data(bytes: idPointer, count: fido_cred_id_len(credential))

            return AccountHandle(account: Account(id: trimmedId,
                                                  kind: kind,
                                                  credentialIdB64: credentialId.base64EncodedString(),
                                                  portable: nil),
                                 devicePath: path)
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
                           pin: String?) throws -> [AccountHandle] {
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
            var accounts: [AccountHandle] = []
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
                let portable = Self.decodeUserFields(kind: kind, name: rawName, displayName: rawDisplayName)

                accounts.append(AccountHandle(account: Account(id: accountId,
                                                               kind: kind,
                                                               credentialIdB64: credentialId.base64EncodedString(),
                                                               portable: portable),
                                              devicePath: path))
            }
            return accounts
        }
    }

    func deleteAccount(_ handle: AccountHandle, pin: String?) throws {
        guard let credId = Data(base64Encoded: handle.account.credentialIdB64) else {
            throw FidoPassError.invalidState("Credential ID is not valid base64")
        }
        try deviceRepository.withOpenedDevice(path: handle.devicePath) { device, _ in
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

    func updateCredentialUserInfo(_ handle: AccountHandle,
                                  pinProvider: (@Sendable () -> String?)?) throws {
        let account = handle.account
        guard let credentialId = Data(base64Encoded: account.credentialIdB64) else {
            throw FidoPassError.invalidState("Credential ID is not valid base64")
        }
        try deviceRepository.withOpenedDevice(path: handle.devicePath) { device, _ in
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
                                        Self.credentialDisplayName(accountId: account.id),
                                        nil),
                    operation: "cred_set_user(update)")
            }
            try Libfido2Context.check(fido_cred_set_type(residentCredential, COSE_ES256), operation: "cred_set_type(update)")

            // The result used to be discarded, so a rejected write looked like success and
            // the change silently vanished on the next reload.
            try PinScope.withPIN(pinProvider?()) { pinCString in
                try Libfido2Context.check(fido_credman_set_dev_rk(device, residentCredential, pinCString),
                                          operation: "credman_set_dev_rk")
            }
        }
    }

    // MARK: - Credential user fields

    /// Value written to the credential's `name` field.
    ///
    /// For a portable account this carries the key material, because that is where every
    /// released version of FidoPass looks for it; moving it elsewhere once made accounts
    /// created by this build unreadable by earlier ones. Since identities exist the payload
    /// is 44 bytes rather than 32 (`PortablePayload`), which earlier versions reject with
    /// "must contain base64 External (32 bytes)" — compatibility runs one way: this version
    /// reads every layout ever written, earlier versions read only their own. The value is
    /// 60 characters, under the 64 bytes CTAP lets an authenticator keep for `user.name`.
    static func credentialName(kind: AccountKind,
                                       accountId: String,
                                       portable: PortablePayload?) -> String {
        if kind == .portable, let portable {
            return portable.base64
        }
        return String(accountId.prefix(32))
    }


    /// Value written to the credential's `displayName` field: the account id, always.
    ///
    /// Never empty: an empty display name makes `fido_dev_make_cred` fail with
    /// `FIDO_ERR_INVALID_LENGTH` before the request even reaches the authenticator, so
    /// enrolment dies instantly with an error that names no cause. Never anything else
    /// either: a portable account's `name` field is taken by the key material, so the
    /// account id here is the layout every released version writes and expects, and nothing
    /// in the app ever showed a display name.
    static func credentialDisplayName(accountId: String) -> String {
        accountId
    }

    /// Reads the portable key material back out of the two credential strings.
    ///
    /// The written layout puts a portable payload in `name` — 32 bytes from earlier versions,
    /// 32 plus a 12-byte identity from this one; `PortablePayload` tells them apart by length
    /// and reports the first as needing migration. The prefixed `displayName` form is still
    /// accepted because builds between the refactor and its fix wrote it, and those accounts
    /// are on real keys — losing the payload would make their passwords unreproducible. A
    /// local account never carries any, whatever its strings happen to look like.
    static func decodeUserFields(kind: AccountKind,
                                 name: String,
                                 displayName: String) -> PortablePayload? {
        guard kind == .portable else { return nil }
        if displayName.hasPrefix(portablePayloadPrefix) {
            let encoded = String(displayName.dropFirst(portablePayloadPrefix.count))
            return PortablePayload(base64: encoded)
        }
        return PortablePayload(base64: name)
    }

    private static func encodeUserId(_ accountId: String) throws -> Data {
        let data = Data(accountId.utf8)
        if data.isEmpty || data.count > 64 {
            throw FidoPassError.invalidState("Account ID must be 1–64 bytes when UTF-8 encoded")
        }
        return data
    }
}
