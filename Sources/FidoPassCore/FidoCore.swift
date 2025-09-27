import Foundation
import CryptoKit
import CLibfido2

public enum FidoPassError: Error, LocalizedError {
    case libfido2(String)
    case noDevices
    case unsupported(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .libfido2(let s): return s
        case .noDevices: return "No FIDO devices found"
        case .unsupported(let s): return "Unsupported feature: \(s)"
        case .invalidState(let s): return s
        }
    }
}

// MARK: - Helpers

@inline(__always)
private func check(_ rc: Int32, _ what: String) throws {
    if rc != FIDO_OK {
        let msg = String(cString: fido_strerr(rc))
        throw FidoPassError.libfido2("\(what): \(msg)")
    }
}

private func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess)
    return Data(bytes)
}

// Deterministic salt derivation from label + rpId + accountId
private func salt32(label: String, rpId: String, accountId: String, revision: Int) -> Data {
    var hasher = SHA256()
    hasher.update(data: Data("fidopass|salt|".utf8))
    hasher.update(data: Data(rpId.utf8))
    hasher.update(data: Data("|".utf8))
    hasher.update(data: Data(accountId.utf8))
    hasher.update(data: Data("|".utf8))
    hasher.update(data: Data(label.utf8))
    hasher.update(data: Data("|".utf8))
    hasher.update(data: withUnsafeBytes(of: UInt32(revision).bigEndian, { Data($0) }))
    return Data(hasher.finalize()) // 32 bytes
}

// MARK: - Models

public struct PasswordPolicy: Codable, Hashable {
    public var length: Int
    public var useLower: Bool
    public var useUpper: Bool
    public var useDigits: Bool
    public var useSymbols: Bool
    public var avoidAmbiguous: Bool
    public var version: Int

    public init(length: Int = 20, useLower: Bool = true, useUpper: Bool = true, useDigits: Bool = true, useSymbols: Bool = true, avoidAmbiguous: Bool = true, version: Int = 1) {
        self.length = length
        self.useLower = useLower
        self.useUpper = useUpper
        self.useDigits = useDigits
        self.useSymbols = useSymbols
        self.avoidAmbiguous = avoidAmbiguous
        self.version = version
    }
}

public struct Account: Codable, Hashable, Identifiable {
    public var id: String         // arbitrary account identifier (unique)
    public var rpId: String       // RP ID (regular: fidopass.local, portable: fidopass.portable)
    public var userName: String   // regular mode: displayName; portable: base64(External) (32 bytes -> 44 chars)
    public var credentialIdB64: String // credentialId encoded as base64
    public var revision: Int      // salt/policy revision counter
    public var policy: PasswordPolicy
    public var devicePath: String? // HID device path/identifier

    public static func ==(lhs: Account, rhs: Account) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public final class FidoPassCore {
    public static let shared = FidoPassCore()
    public init() { fido_init(0) }

    // MARK: Simplified metadata helpers
    private func encodeUserId(_ accountId: String) throws -> Data {
        let data = Data(accountId.utf8)
        if data.count == 0 || data.count > 64 { throw FidoPassError.invalidState("accountId length invalid") }
        return data
    }
    private func decodeUserId(_ data: Data) -> String? { String(data: data, encoding: .utf8) }

    private func unpackMeta(_ data: Data) -> (accountId: String, revision: Int, policy: PasswordPolicy)? {
        guard data.count >= 5 else { return nil }
        let magic = data[0]
        guard magic == 0xA3 else { return nil }
        let rev = Int(data[1])
        let length = Int(data[2])
        let flags = data[3]
        let accLen = Int(data[4])
        guard accLen <= 59, 5 + accLen <= data.count else { return nil }
        let accData = data.subdata(in: 5 ..< 5+accLen)
        guard let accId = String(data: accData, encoding: .utf8) else { return nil }
        let policy = PasswordPolicy(length: length,
                                    useLower: (flags & 0x01) != 0,
                                    useUpper: (flags & 0x02) != 0,
                                    useDigits: (flags & 0x04) != 0,
                                    useSymbols: (flags & 0x08) != 0,
                                    avoidAmbiguous: (flags & 0x10) != 0,
                                    version: 1)
        return (accId, rev, policy)
    }

    // MARK: Device listing
    public struct FidoDevice: Identifiable, Hashable, Codable {
        public var id: String { path }
        public let path: String
        public let product: String
        public let manufacturer: String

        public var displayName: String {
            manufacturer.isEmpty ? product : "\(manufacturer) \(product)"
        }
    }
    public func listDevices(limit: Int = 16) throws -> [FidoDevice] {
        guard let rawList = fido_dev_info_new(limit) else { throw FidoPassError.noDevices }
        var devlist: OpaquePointer? = rawList
        defer { fido_dev_info_free(&devlist, limit) }
        var olen: Int = 0; try check(fido_dev_info_manifest(devlist, limit, &olen), "dev_info_manifest")
        if olen == 0 { return [] }
        var out: [FidoDevice] = []
        for i in 0..<olen {
            guard let di = fido_dev_info_ptr(devlist, size_t(i)), let cpath = fido_dev_info_path(di) else { continue }
            let path = String(cString: cpath)
            let prod = fido_dev_info_product_string(di).map { String(cString: $0) } ?? "Unknown"
            let manu = fido_dev_info_manufacturer_string(di).map { String(cString: $0) } ?? ""
            out.append(FidoDevice(path: path, product: prod, manufacturer: manu))
        }
        return out
    }

    // MARK: Internal helpers
    private func firstDevicePath() throws -> String {
        let max = 16
        guard let rawList = fido_dev_info_new(max) else { throw FidoPassError.noDevices }
        var devlist: OpaquePointer? = rawList
        defer { fido_dev_info_free(&devlist, max) }
        var olen: Int = 0; try check(fido_dev_info_manifest(devlist, max, &olen), "dev_info_manifest")
        guard olen > 0, let di = fido_dev_info_ptr(devlist, 0), let cpath = fido_dev_info_path(di) else { throw FidoPassError.noDevices }
        return String(cString: cpath)
    }
    private func withOpenedDevice<T>(path: String? = nil, _ body: (OpaquePointer, String) throws -> T) throws -> T {
        let path = try path ?? firstDevicePath()
        guard let dev = fido_dev_new() else { throw FidoPassError.invalidState("fido_dev_new") }
        defer { fido_dev_close(dev); var d: OpaquePointer? = dev; fido_dev_free(&d) }
        try check(fido_dev_open(dev, path), "open \(path)")
        return try body(dev, path)
    }
    private func ensureHmacSecretSupported(_ dev: OpaquePointer) throws {
        guard let rawInfo = fido_cbor_info_new() else { throw FidoPassError.invalidState("cbor_info_new") }
        var ci: OpaquePointer? = rawInfo
        defer { fido_cbor_info_free(&ci) }
        try check(fido_dev_get_cbor_info(dev, ci), "get_cbor_info")
        let n = fido_cbor_info_extensions_len(ci)
        guard let pptr = fido_cbor_info_extensions_ptr(ci) else { throw FidoPassError.unsupported("extension list is unavailable") }
        var ok = false
        for i in 0..<n { if let ext = pptr.advanced(by: Int(i)).pointee { if String(cString: ext) == "hmac-secret" { ok = true; break } } }
        if !ok { throw FidoPassError.unsupported("Authenticator does not support hmac-secret") }
    }

    // MARK: Enrollment (makeCredential)
    // residentKey defaults to TRUE (discoverable credential)
    public func enroll(accountId: String, rpId: String = "fidopass.local", userName: String = "", requireUV: Bool = true, residentKey: Bool = true, devicePath: String? = nil, askPIN: (() -> String?)? = nil) throws -> Account {
        try withOpenedDevice(path: devicePath) { dev, path in
            try ensureHmacSecretSupported(dev)
            guard residentKey else { throw FidoPassError.invalidState("Non-resident credentials are not supported without local storage") }
            guard let rawCred = fido_cred_new() else { throw FidoPassError.invalidState("cred_new") }
            var cred: OpaquePointer? = rawCred
            defer { fido_cred_free(&cred) }
            try check(fido_cred_set_type(cred, COSE_ES256), "cred_set_type")
            try check(fido_cred_set_extensions(cred, Int32(FIDO_EXT_HMAC_SECRET)), "cred_set_extensions(hmac-secret)")
            try check(fido_cred_set_rp(cred, rpId, "FidoPass"), "cred_set_rp")
            let packed = try encodeUserId(accountId)
            // user.name (short) always uses accountId (non-empty, unique, concise); some authenticators reject empty strings.
            // displayName = requested user-visible name (may be empty for portable accounts — accountId is used as a fallback when enumerating).
            let shortName = String(accountId.prefix(32)) // limit for authenticator constraints
            let displayName = userName.isEmpty ? accountId : userName // ensure non-empty displayName
            try packed.withUnsafeBytes { ptr in
                try check(fido_cred_set_user(cred,
                                             ptr.bindMemory(to: UInt8.self).baseAddress,
                                             packed.count,
                                             shortName,    // user.name (short, stable)
                                             displayName,  // displayName (may be empty)
                                             nil),
                          "cred_set_user")
            }
            try check(fido_cred_set_rk(cred, FIDO_OPT_TRUE), "cred_set_rk")
            try check(fido_cred_set_uv(cred, requireUV ? FIDO_OPT_TRUE : FIDO_OPT_OMIT), "cred_set_uv")
            let challenge = randomBytes(32)
            try challenge.withUnsafeBytes { ptr in
                try check(fido_cred_set_clientdata_hash(cred, ptr.bindMemory(to: UInt8.self).baseAddress, challenge.count), "cred_set_clientdata_hash")
            }
            var pinCString: UnsafePointer<CChar>? = nil
            if requireUV, let ask = askPIN, let pin = ask() { pinCString = UnsafePointer(strdup(pin)) }
            defer { if pinCString != nil { free(UnsafeMutableRawPointer(mutating: pinCString)) } }
            try check(fido_dev_make_cred(dev, cred, pinCString), "dev_make_cred")
            guard let idPtr = fido_cred_id_ptr(cred) else { throw FidoPassError.invalidState("cred_id_ptr") }
            let idLen = fido_cred_id_len(cred)
            let credId = Data(bytes: idPtr, count: idLen)
            return Account(id: accountId, rpId: rpId, userName: userName, credentialIdB64: credId.base64EncodedString(), revision: 1, policy: PasswordPolicy(), devicePath: path)
        }
    }

    // MARK: Portable enrollment (rpId = fidopass.portable)
    // importedKeyB64: if a 32-byte ImportedKey (base64) is provided, derive External = ImportedKey XOR A and persist externalKeyB64 = External
    // if nil -> generate a new ImportedKey (random 32 bytes), persist the external value and return the ImportedKey for display/export
    public func enrollPortable(accountId: String, requireUV: Bool = true, devicePath: String? = nil, askPIN: (() -> String?)? = nil, importedKeyB64: String?) throws -> (Account, generatedImportedKeyB64: String?) {
        let rpId = "fidopass.portable"
        // Enroll with empty user.name; user.id (metadata) immutable. Later we only set user.name to external base64.
        let account = try enroll(accountId: accountId, rpId: rpId, userName: "", requireUV: requireUV, residentKey: true, devicePath: devicePath, askPIN: askPIN)
        // derive A
        let a = try deriveFixedComponent(account: account, requireUV: requireUV, pinProvider: askPIN)
        let importedKey: Data
        if let given = importedKeyB64 {
            guard let data = Data(base64Encoded: given), data.count == 32 else { throw FidoPassError.invalidState("ImportedKey base64 must be 32 bytes") }
            importedKey = data
        } else {
            importedKey = randomBytes(32)
        }
        // External = ImportedKey XOR A
        guard a.count == 32 else { throw FidoPassError.invalidState("Fixed component !=32") }
        let external = Data(zip(importedKey, a).map { $0 ^ $1 })
        var acc2 = account
        acc2.userName = external.base64EncodedString() // store external in model
        // Best-effort: set authenticator user.name (NOT user.id) to external base64; user_id stays immutable.
        try? setCredentialUserName(account: acc2, newUserName: acc2.userName, requireUV: requireUV, pinProvider: askPIN)
        return (acc2, importedKeyB64 == nil ? importedKey.base64EncodedString() : nil)
    }

    private func deriveFixedComponent(account: Account, requireUV: Bool, pinProvider: (() -> String?)?) throws -> Data {
        let salt = Data(SHA256.hash(data: Data("fidopass|fixed-challenge|v1".utf8)))
        return try performHmacSecret(account: account, salt: salt, requireUV: requireUV, pinProvider: pinProvider)
    }

    // Use Credential Management to set user.name (display name left unchanged -> account.id)
    private func setCredentialUserName(account: Account, newUserName: String, requireUV: Bool, pinProvider: (() -> String?)?) throws {
        // Only update user.name. user.id (metadata) must remain original: for portable -> empty userName; for normal -> stored display userName.
        guard let credId = Data(base64Encoded: account.credentialIdB64) else { return }
        try withOpenedDevice(path: account.devicePath) { dev, _ in
            guard let rkCred = fido_cred_new() else { throw FidoPassError.invalidState("cred_new") }
            defer { var c: OpaquePointer? = rkCred; fido_cred_free(&c) }
            try check(fido_cred_set_rp(rkCred, account.rpId, "FidoPass"), "cred_set_rp(update)")
            try credId.withUnsafeBytes { ptr in
                try check(fido_cred_set_id(rkCred, ptr.bindMemory(to: UInt8.self).baseAddress, credId.count), "cred_set_id")
            }
            let meta = (try? encodeUserId(account.id)) ?? Data()
            try meta.withUnsafeBytes { mptr in
                try check(fido_cred_set_user(rkCred,
                                             mptr.bindMemory(to: UInt8.self).baseAddress,
                                             meta.count,
                                             newUserName,   // new user.name only
                                             account.id,    // display name stable
                                             nil),
                          "cred_set_user(update)")
            }
            try check(fido_cred_set_type(rkCred, COSE_ES256), "cred_set_type(update)")
            var pinCString: UnsafePointer<CChar>? = nil
            if requireUV, let pin = pinProvider?() { pinCString = UnsafePointer(strdup(pin)) }
            defer { if pinCString != nil { free(UnsafeMutableRawPointer(mutating: pinCString)) } }
            _ = fido_credman_set_dev_rk(dev, rkCred, pinCString) // ignore result
        }
    }

    private func performHmacSecret(account: Account, salt: Data, requireUV: Bool, pinProvider: (() -> String?)?) throws -> Data {
        return try withOpenedDevice(path: account.devicePath) { dev, _ in
            try ensureHmacSecretSupported(dev)
            guard let rawAssert = fido_assert_new() else { throw FidoPassError.invalidState("assert_new") }
            var assertion: OpaquePointer? = rawAssert
            defer { fido_assert_free(&assertion) }

            try check(fido_assert_set_rp(assertion, account.rpId), "assert_set_rp")

            let credId = Data(base64Encoded: account.credentialIdB64)!
            try credId.withUnsafeBytes { ptr in
                try check(fido_assert_allow_cred(assertion,
                                                 ptr.bindMemory(to: UInt8.self).baseAddress,
                                                 credId.count),
                          "assert_allow_cred")
            }

            try check(fido_assert_set_extensions(assertion, Int32(FIDO_EXT_HMAC_SECRET)), "assert_set_extensions(hmac-secret)")
            try salt.withUnsafeBytes { ptr in
                try check(fido_assert_set_hmac_salt(assertion,
                                                    ptr.bindMemory(to: UInt8.self).baseAddress,
                                                    salt.count),
                          "assert_set_hmac_salt")
            }

            try check(fido_assert_set_up(assertion, FIDO_OPT_TRUE), "assert_set_up")
            try check(fido_assert_set_uv(assertion, requireUV ? FIDO_OPT_TRUE : FIDO_OPT_OMIT), "assert_set_uv")

            let challenge = randomBytes(32)
            try challenge.withUnsafeBytes { ptr in
                try check(fido_assert_set_clientdata_hash(assertion,
                                                          ptr.bindMemory(to: UInt8.self).baseAddress,
                                                          challenge.count),
                          "assert_set_clientdata_hash")
            }

            var pinCString: UnsafePointer<CChar>? = nil
            if requireUV, let pin = pinProvider?() {
                pinCString = UnsafePointer(strdup(pin))
            }
            defer { if pinCString != nil { free(UnsafeMutableRawPointer(mutating: pinCString)) } }

            try check(fido_dev_get_assert(dev, assertion, pinCString), "dev_get_assert")

            guard let hmacPtr = fido_assert_hmac_secret_ptr(assertion, 0) else {
                throw FidoPassError.invalidState("assert_hmac_secret_ptr=NULL")
            }
            let length = fido_assert_hmac_secret_len(assertion, 0)
            return Data(bytes: hmacPtr, count: length)
        }
    }

    // MARK: Derive hmac-secret
    public func deriveSecret(account: Account, label: String, requireUV: Bool = true, pinProvider: (() -> String?)? = nil) throws -> Data {
        let salt = salt32(label: label, rpId: account.rpId, accountId: account.id, revision: account.revision)
        return try performHmacSecret(account: account, salt: salt, requireUV: requireUV, pinProvider: pinProvider)
    }

    // MARK: Password generation
    // Portable passwords must depend only on ImportedKey, label, and policy.
    // Use a dedicated salt portableLabelSalt(label) = SHA256("fidopass|portable|" + label)
    private func portableLabelSalt(_ label: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("fidopass|portable|".utf8))
        hasher.update(data: Data(label.utf8))
        return Data(hasher.finalize())
    }
    public func generatePassword(account: Account, label: String, policy override: PasswordPolicy? = nil, requireUV: Bool = true, pinProvider: (() -> String?)? = nil) throws -> String {
        let policy = override ?? account.policy
        let secret: Data
        if account.rpId == "fidopass.portable" {
            guard let external = Data(base64Encoded: account.userName), external.count == 32 else { throw FidoPassError.invalidState("Portable userName must contain base64 External (32 bytes)") }
            // Reconstruct ImportedKey = External XOR A
            let a = try deriveFixedComponent(account: account, requireUV: requireUV, pinProvider: pinProvider)
            guard a.count == 32 else { throw FidoPassError.invalidState("Fixed component size !=32") }
            let importedKey = Data(zip(a, external).map { $0 ^ $1 })
            // Salt depends only on the label to stay deterministic across devices
            let challengeSalt = portableLabelSalt(label)
            let mac = HMAC<SHA256>.authenticationCode(for: challengeSalt, using: SymmetricKey(data: importedKey))
            secret = Data(mac)
        } else {
            secret = try deriveSecret(account: account, label: label, requireUV: requireUV, pinProvider: pinProvider)
        }
        let ikm = SymmetricKey(data: secret)
        let info = Data("fidopass|pw|v\(policy.version)".utf8)
        let salt = Data("pw-map".utf8)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: max(64, policy.length * 3))
        let kBytes = Data(derived.withUnsafeBytes { Data($0) })
        return PasswordEngine.mapToPassword(kBytes, policy: policy)
    }

    // MARK: Enumerate resident credentials (assertion fallback; credman variant pending stable bindings)
    public func enumerateAccounts(rpId: String = "fidopass.local", devicePath: String, pin: String?) throws -> [Account] {
        try withOpenedDevice(path: devicePath) { dev, path in
            guard let rawAssert = fido_assert_new() else { throw FidoPassError.invalidState("assert_new") }
            var assert: OpaquePointer? = rawAssert
            defer { fido_assert_free(&assert) }
            try check(fido_assert_set_rp(assert, rpId), "assert_set_rp")
            let challenge = randomBytes(32)
            try challenge.withUnsafeBytes { ptr in
                try check(fido_assert_set_clientdata_hash(assert, ptr.bindMemory(to: UInt8.self).baseAddress, challenge.count), "assert_set_clientdata_hash")
            }
            try check(fido_assert_set_up(assert, FIDO_OPT_FALSE), "assert_set_up")
            if pin != nil { _ = fido_assert_set_uv(assert, FIDO_OPT_TRUE) }
            var pinCString: UnsafePointer<CChar>? = nil
            if let p = pin { pinCString = UnsafePointer(strdup(p)) }
            defer { if pinCString != nil { free(UnsafeMutableRawPointer(mutating: pinCString)) } }
            let rc = fido_dev_get_assert(dev, assert, pinCString)
            if rc == FIDO_ERR_NO_CREDENTIALS { return [] }
            if rc != FIDO_OK { let msg = String(cString: fido_strerr(rc)); throw FidoPassError.libfido2("dev_get_assert(enumerate): \(msg)") }
            let count = Int(fido_assert_count(assert))
            var out: [Account] = []
            for i in 0..<count {
                let namePtr = fido_assert_user_name(assert, i)
                let dispPtr = fido_assert_user_display_name(assert, i)
                guard let idPtr = fido_assert_id_ptr(assert, i) else { continue }
                let idLen = fido_assert_id_len(assert, i)
                let credId = Data(bytes: idPtr, count: idLen)
                let displayName = dispPtr.map { String(cString: $0) } ?? ""
                var accId: String? = nil
                if let uidPtr = fido_assert_user_id_ptr(assert, i) {
                    let uidLen = fido_assert_user_id_len(assert, i)
                    let uidData = Data(bytes: uidPtr, count: uidLen)
                    accId = decodeUserId(uidData)
                }
                guard let accountId = accId else { continue }
                var finalUserName = displayName
                if rpId == "fidopass.portable", let namePtr = namePtr {
                    let uname = String(cString: namePtr)
                    if let d = Data(base64Encoded: uname), d.count == 32 { finalUserName = uname }
                }
                out.append(Account(id: accountId, rpId: rpId, userName: finalUserName, credentialIdB64: credId.base64EncodedString(), revision: 1, policy: PasswordPolicy(), devicePath: path))
            }
            return out
        }
    }

    // MARK: Export ImportedKey for portable
    public func exportImportedKey(_ account: Account, requireUV: Bool = true, pinProvider: (() -> String?)? = nil) throws -> String {
        guard account.rpId == "fidopass.portable" else { throw FidoPassError.invalidState("Account is not portable") }
        guard let external = Data(base64Encoded: account.userName), external.count == 32 else { throw FidoPassError.invalidState("userName does not contain a valid external base64 payload") }
        let a = try deriveFixedComponent(account: account, requireUV: requireUV, pinProvider: pinProvider)
        guard a.count == 32 else { throw FidoPassError.invalidState("Fixed component size !=32") }
        let imported = Data(zip(a, external).map { $0 ^ $1 })
        return imported.base64EncodedString()
    }

    // MARK: Delete resident credential (best-effort)
    // Requires authenticator supporting credential management (credProtect / credMgmt).
    public func deleteAccount(_ account: Account, pin: String?) throws {
        let credId = Data(base64Encoded: account.credentialIdB64)!
        try withOpenedDevice(path: account.devicePath) { dev, _ in
            var pinCString: UnsafePointer<CChar>? = nil
            if let pin = pin { pinCString = UnsafePointer(strdup(pin)) }
            defer { if pinCString != nil { free(UnsafeMutableRawPointer(mutating: pinCString)) } }
            let rc = credId.withUnsafeBytes { ptr -> Int32 in
                fido_credman_del_dev_rk(dev, ptr.bindMemory(to: UInt8.self).baseAddress, credId.count, pinCString)
            }
            if rc == FIDO_ERR_INVALID_COMMAND { throw FidoPassError.unsupported("Credential Management is not supported by the device") }
            if rc == FIDO_ERR_PIN_REQUIRED { throw FidoPassError.invalidState("PIN is required for deletion") }
            if rc != FIDO_OK { let msg = String(cString: fido_strerr(rc)); throw FidoPassError.libfido2("credman_del: \(msg)") }
        }
    }
}

// (legacy decoding removed)
