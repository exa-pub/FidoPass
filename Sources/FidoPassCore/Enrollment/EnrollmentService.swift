import Foundation
import CLibfido2

final class EnrollmentService: Enrolling, Sendable {
    /// Marks a v1 portable payload stored in the credential's display-name field — a layout
    /// a few intermediate builds wrote. Read, never written.
    private static let portablePayloadPrefix = "fp-ext:v1:"

    private let deviceRepository: DeviceAccessing

    init(deviceRepository: DeviceAccessing) {
        self.deviceRepository = deviceRepository
    }

    // MARK: - Creating

    func enroll(accountId: String,
                kind: AccountKind,
                identity: AccountIdentity,
                devicePath: String,
                askPIN: (@Sendable () -> String?)?,
                namesakePolicy: NamesakePolicy) throws -> AccountHandle {
        let trimmedId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = try Self.encodeUserName(trimmedId)

        guard let pin = askPIN?(), !pin.isEmpty else {
            throw FidoPassError.invalidState("A PIN is required to create an account")
        }

        return try deviceRepository.withOpenedDevice(path: devicePath) { device, path in
            // Check raw user handles, including credentials with missing/corrupt records,
            // in the same open as creation. An unreadable key is never an empty key.
            for rpId in AccountFormat.relyingPartyIds {
                try Self.forEachResidentCredential(device: device, rpId: rpId, pin: pin) { existing in
                    let userID = fido_cred_user_id_ptr(existing).map {
                        Data(bytes: $0, count: fido_cred_user_id_len(existing))
                    } ?? Data()
                    if rpId == AccountFormat.v2RelyingPartyId, userID == identity.bytes {
                        throw FidoPassError.invalidState("This identity already belongs to an account on this key")
                    }
                    let parsed = AccountFormat.parse(rpId: rpId)
                    let existingName = parsed?.0 == .v1
                        ? String(data: userID, encoding: .utf8)
                        : fido_cred_user_name(existing).map { String(cString: $0) }
                    if existingName == trimmedId {
                        let legacyTwin = namesakePolicy == .allowLegacyTwin && parsed?.0 == .v1 && parsed?.1 == .portable
                        guard legacyTwin else {
                            throw FidoPassError.invalidState("An account with this name already exists on this key")
                        }
                    }
                }
            }
            try deviceRepository.ensureHmacSecretSupported(device)
            guard try CborInfo.with(device: device, { $0.supportsLargeBlobs }) else {
                throw FidoPassError.unsupported("This key has no large-blob store, which every new account needs. Accounts already on it keep working.")
            }
            guard let credential = fido_cred_new() else {
                throw FidoPassError.invalidState("cred_new")
            }
            var cred: OpaquePointer? = credential
            defer { fido_cred_free(&cred) }

            try Libfido2Context.check(fido_cred_set_type(credential, COSE_ES256), operation: "cred_set_type")
            try Libfido2Context.check(fido_cred_set_extensions(credential, Int32(FIDO_EXT_HMAC_SECRET | FIDO_EXT_LARGEBLOB_KEY | FIDO_EXT_CRED_PROTECT)),
                                      operation: "cred_set_extensions")
            // UV required: without the PIN the credential answers nothing at all, rather
            // than answering with the other CredRandom and deriving something different.
            try Libfido2Context.check(fido_cred_set_prot(credential, FIDO_CRED_PROT_UV_REQUIRED), operation: "cred_set_prot")
            try Libfido2Context.check(fido_cred_set_rp(credential, AccountFormat.v2RelyingPartyId, "FidoPass"), operation: "cred_set_rp")

            try identity.bytes.withUnsafeBytes { pointer in
                try Libfido2Context.check(
                    fido_cred_set_user(credential,
                                        pointer.bindMemory(to: UInt8.self).baseAddress,
                                        identity.bytes.count,
                                        name,
                                        name,
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

            try PinScope.withPIN(pin) { pinCString in
                try Libfido2Context.check(fido_dev_make_cred(device, credential, pinCString), operation: "dev_make_cred")
            }

            guard let idPointer = fido_cred_id_ptr(credential) else {
                throw FidoPassError.invalidState("cred_id_ptr")
            }
            let credentialId = Data(bytes: idPointer, count: fido_cred_id_len(credential))

            var account = Account(id: trimmedId,
                                  kind: kind,
                                  format: .v2,
                                  credentialIdB64: credentialId.base64EncodedString(),
                                  identity: identity,
                                  mask: nil,
                                  integrity: .recordMissing)

            // A local account's record needs nothing more than the credential, so it is
            // written here, inside the same open. A portable one needs its mask first —
            // another touch — and `PortableEnrollmentService` writes it afterwards.
            if kind == .local {
                do {
                    guard let key = LargeBlobStore.key(of: credential) else {
                        throw FidoPassError.invalidState("The key returned no large-blob key for the new credential")
                    }
                    try LargeBlobStore.write(device: device, key: key, blob: AccountRecord(kind: .local, mask: nil)!.encoded, pin: pin)
                    account.integrity = .ok
                } catch {
                    // A credential without a record is not an account: take it back off the
                    // key rather than leave a slot occupied by something the app cannot use.
                    guard KeyFailurePolicy.allowsAuthenticatedRecovery(after: error) else {
                        throw KeyMutationError(completed: .credentialCreated, underlying: error)
                    }
                    do { try Self.deleteCredential(device: device, credentialId: credentialId, pin: pin) }
                    catch { throw KeyMutationError(completed: .credentialCreated, underlying: error) }
                    throw error
                }
            }

            return AccountHandle(account: account, devicePath: path)
        }
    }

    // MARK: - Reading

    /// Reads all account formats in one open using PIN-authenticated credential management.
    /// Unlike a silent assertion, credman returns the full user entity needed for v1 masks
    /// and the large-blob key needed to read v2 records.
    func enumerateAccounts(devicePath: String,
                           pin: String?) throws -> [AccountHandle] {
        guard let pin, !pin.isEmpty else {
            throw FidoPassError.invalidState("A PIN is required to list accounts on the key")
        }

        return try deviceRepository.withOpenedDevice(path: devicePath) { device, path in
            var accounts: [AccountHandle] = []
            for rpId in AccountFormat.relyingPartyIds {
                try Self.forEachResidentCredential(device: device, rpId: rpId, pin: pin) { credential in
                    if let account = try Self.account(from: credential, rpId: rpId, device: device) {
                        accounts.append(AccountHandle(account: account, devicePath: path))
                    }
                }
            }
            return accounts
        }
    }

    // MARK: - Writing and deleting

    func deleteAccount(_ handle: AccountHandle, pin: String?) throws {
        guard let credentialId = Data(base64Encoded: handle.account.credentialIdB64) else {
            throw FidoPassError.invalidState("Credential ID is not valid base64")
        }
        try deviceRepository.withOpenedDevice(path: handle.devicePath) { device, _ in
            // Keep the key in memory before deletion. Delete the credential first so a
            // failed credential deletion can never strand a portable account without its mask.
            let key = handle.account.format == .v2
                ? try Self.largeBlobKey(device: device, credentialIdB64: handle.account.credentialIdB64, pin: pin)
                : nil
            try Self.deleteCredential(device: device, credentialId: credentialId, pin: pin)
            if let key {
                do { try LargeBlobStore.remove(device: device, key: key, pin: pin) }
                catch { throw KeyMutationError(completed: .credentialDeleted, underlying: error) }
            }
        }
    }

    func writeRecord(for handle: AccountHandle,
                     pinProvider: (@Sendable () -> String?)?) throws {
        guard handle.account.format == .v2 else {
            throw FidoPassError.invalidState("Only a v2 account has a record")
        }
        guard let record = AccountRecord(kind: handle.account.kind, mask: handle.account.mask) else {
            throw FidoPassError.invalidState("A portable account's record needs its 32-byte mask")
        }
        try deviceRepository.withOpenedDevice(path: handle.devicePath) { device, _ in
            let pin = pinProvider?()
            let key = try Self.largeBlobKey(device: device, credentialIdB64: handle.account.credentialIdB64, pin: pin)
            try LargeBlobStore.write(device: device, key: key, blob: record.encoded, pin: pin)
        }
    }

    // MARK: - Credential management helpers

    private static func deleteCredential(device: OpaquePointer, credentialId: Data, pin: String?) throws {
        let rc = try PinScope.withPIN(pin) { pinCString in
            credentialId.withUnsafeBytes { pointer -> Int32 in
                fido_credman_del_dev_rk(device,
                                        pointer.bindMemory(to: UInt8.self).baseAddress,
                                        credentialId.count,
                                        pinCString)
            }
        }
        if rc == FIDO_ERR_PIN_REQUIRED {
            throw FidoPassError.invalidState("PIN is required for deletion")
        }
        try Libfido2Context.checkCredman(rc, operation: "credman_del")
    }

    /// The large-blob key of a v2 credential, read back from credential management. One
    /// silent round-trip; the key is used on the spot and never stored in a model.
    private static func largeBlobKey(device: OpaquePointer, credentialIdB64: String, pin: String?) throws -> Data {
        var found: Data?
        try forEachResidentCredential(device: device, rpId: AccountFormat.v2RelyingPartyId, pin: pin) { credential in
            guard found == nil, let idPointer = fido_cred_id_ptr(credential) else { return }
            let credentialId = Data(bytes: idPointer, count: fido_cred_id_len(credential))
            if credentialId.base64EncodedString() == credentialIdB64 {
                found = LargeBlobStore.key(of: credential)
            }
        }
        guard let found else {
            throw FidoPassError.invalidState("The key returned no large-blob key for this credential")
        }
        return found
    }

    private static func forEachResidentCredential(device: OpaquePointer,
                                                  rpId: String,
                                                  pin: String?,
                                                  _ body: (OpaquePointer) throws -> Void) throws {
        guard let rawList = fido_credman_rk_new() else {
            throw FidoPassError.invalidState("credman_rk_new")
        }
        var residentKeys: OpaquePointer? = rawList
        defer { fido_credman_rk_free(&residentKeys) }

        let rc = try PinScope.withPIN(pin) { fido_credman_get_dev_rk(device, rpId, rawList, $0) }
        // An authenticator with nothing stored for this relying party reports it as an
        // error rather than an empty list.
        if rc == FIDO_ERR_NO_CREDENTIALS { return }
        try Libfido2Context.checkCredman(rc, operation: "credman_get_dev_rk")

        for index in 0..<fido_credman_rk_count(rawList) {
            guard let credential = fido_credman_rk(rawList, index) else { continue }
            try body(credential)
        }
    }

    /// One credential as read through credential management, as an account — or `nil` when
    /// it is not one FidoPass can name at all.
    private static func account(from credential: OpaquePointer, rpId: String, device: OpaquePointer) throws -> Account? {
        guard let parsed = AccountFormat.parse(rpId: rpId),
              let credentialPointer = fido_cred_id_ptr(credential) else { return nil }
        let credentialId = Data(bytes: credentialPointer, count: fido_cred_id_len(credential))
        let userIdLength = fido_cred_user_id_len(credential)
        let userId = userIdLength > 0
            ? fido_cred_user_id_ptr(credential).map { Data(bytes: $0, count: userIdLength) } ?? Data()
            : Data()
        let rawName = fido_cred_user_name(credential).map { String(cString: $0) } ?? ""
        let rawDisplayName = fido_cred_display_name(credential).map { String(cString: $0) } ?? ""

        switch parsed {
        case (.v1, let kind?):
            guard let accountId = String(data: userId, encoding: .utf8) else { return nil }
            switch kind {
            case .local:
                return Account(id: accountId,
                               kind: .local,
                               format: .v1,
                               credentialIdB64: credentialId.base64EncodedString(),
                               identity: .derived(fromCredentialId: credentialId))
            case .portable:
                let payload = decodeUserFields(kind: kind, name: rawName, displayName: rawDisplayName)
                return Account(id: accountId,
                               kind: .portable,
                               format: .v1,
                               credentialIdB64: credentialId.base64EncodedString(),
                               identity: nil,
                               mask: payload?.external,
                               integrity: payload == nil ? .recordCorrupt : .ok)
            }
        case (.v1, nil):
            return nil
        case (.v2, _):
            let name = !rawName.isEmpty ? rawName : (!rawDisplayName.isEmpty ? rawDisplayName : String(credentialId.base64EncodedString().prefix(12)))
            let identity = AccountIdentity(bytes: userId)
            var account = Account(id: name,
                                  kind: .local,
                                  format: .v2,
                                  credentialIdB64: credentialId.base64EncodedString(),
                                  identity: identity,
                                  mask: nil,
                                  integrity: identity == nil ? .recordCorrupt : .recordMissing)
            guard identity != nil,
                  let key = LargeBlobStore.key(of: credential),
                  let blob = try LargeBlobStore.read(device: device, key: key) else { return account }
            guard let record = AccountRecord(decoding: blob) else {
                account.integrity = .recordCorrupt
                return account
            }
            account.kind = record.kind
            account.mask = record.mask
            account.integrity = .ok
            return account
        }
    }

    // MARK: - Credential user fields

    /// Reads portable v1 masks from user.name or the historical prefixed displayName.
    /// Both layouts must remain readable; local credentials carry no portable payload.
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

    /// The name as written to `user.name` and `user.displayName`: 1–64 bytes of UTF-8, the
    /// most an authenticator is required to keep. A v2 account's name is a name and nothing
    /// else — no key material, no markers — which is what lets a browser show it as one.
    static func encodeUserName(_ accountId: String) throws -> String {
        guard !accountId.utf8.contains(0) else {
            throw FidoPassError.invalidState("Account ID cannot contain a NUL character")
        }
        let count = accountId.utf8.count
        guard count > 0 else {
            throw FidoPassError.invalidState("Account ID must not be empty")
        }
        guard count <= 64 else {
            throw FidoPassError.invalidState("Account ID must be at most 64 bytes when UTF-8 encoded")
        }
        return accountId
    }
}
