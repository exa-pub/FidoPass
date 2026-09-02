import Foundation
import CLibfido2

/// Reads an authenticator wide rather than deep: everything `getInfo` reports, and every
/// resident credential credential management will list.
///
/// Lives beside `DeviceManagementService` rather than inside `DeviceRepository` for the same
/// reason that one does: the repository is device access, this is an operation performed
/// because a person asked. Nothing here writes to the key.
final class AuthenticatorInspectionService: AuthenticatorInspecting, @unchecked Sendable {

    private let deviceRepository: DeviceRepositoryProtocol

    init(deviceRepository: DeviceRepositoryProtocol) {
        self.deviceRepository = deviceRepository
    }

    // MARK: - Self-description

    func inspect(devicePath: String) throws -> AuthenticatorInfo {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            var pinRetries: Int32 = -1
            let pinRC = fido_dev_get_retry_count(device, &pinRetries)
            var uvRetries: Int32 = -1
            let uvRC = fido_dev_get_uv_retry_count(device, &uvRetries)

            guard let rawInfo = fido_cbor_info_new() else {
                throw FidoPassError.invalidState("cbor_info_new")
            }
            var info: OpaquePointer? = rawInfo
            defer { fido_cbor_info_free(&info) }
            try Libfido2Context.check(fido_dev_get_cbor_info(device, rawInfo), operation: "get_cbor_info")

            let flags = fido_dev_flags(device)
            var capabilities: [String] = []
            if flags & UInt8(FIDO_CAP_WINK) != 0 { capabilities.append("wink") }
            if flags & UInt8(FIDO_CAP_CBOR) != 0 { capabilities.append("cbor") }
            // NMSG is inverted: the bit means the device does *not* speak CTAP1 messages.
            if flags & UInt8(FIDO_CAP_NMSG) == 0 { capabilities.append("msg") }

            let minPIN = fido_cbor_info_minpinlen(rawInfo)
            let rkRemaining = fido_cbor_info_rk_remaining(rawInfo)
            let uvAttempts = fido_cbor_info_uv_attempts(rawInfo)

            return AuthenticatorInfo(
                isFIDO2: fido_dev_is_fido2(device),
                ctapHIDProtocol: Int(fido_dev_protocol(device)),
                ctapHIDVersion: "\(fido_dev_major(device)).\(fido_dev_minor(device)).\(fido_dev_build(device))",
                capabilities: capabilities,
                supportsPIN: fido_dev_supports_pin(device),
                supportsUV: fido_dev_supports_uv(device),
                supportsCredentialManagement: fido_dev_supports_credman(device),
                supportsCredentialProtection: fido_dev_supports_cred_prot(device),
                supportsPermissions: fido_dev_supports_permissions(device),
                hasPIN: fido_dev_has_pin(device),
                hasUV: fido_dev_has_uv(device),
                // A key that declines to say must read as "not reported", never as a number.
                pinRetriesRemaining: (pinRC == FIDO_OK && pinRetries >= 0) ? Int(pinRetries) : nil,
                uvRetriesRemaining: (uvRC == FIDO_OK && uvRetries >= 0) ? Int(uvRetries) : nil,
                versions: Self.strings(fido_cbor_info_versions_ptr(rawInfo),
                                       count: fido_cbor_info_versions_len(rawInfo)),
                extensions: Self.strings(fido_cbor_info_extensions_ptr(rawInfo),
                                         count: fido_cbor_info_extensions_len(rawInfo)),
                options: Self.options(in: rawInfo),
                aaguid: Self.aaguid(in: rawInfo),
                pinProtocols: Self.pinProtocols(in: rawInfo),
                algorithms: Self.algorithms(in: rawInfo),
                transports: Self.strings(fido_cbor_info_transports_ptr(rawInfo),
                                         count: fido_cbor_info_transports_len(rawInfo)),
                certifications: Self.certifications(in: rawInfo),
                firmwareVersion: fido_cbor_info_fwversion(rawInfo),
                limits: AuthenticatorInfo.Limits(
                    maxMessageSize: fido_cbor_info_maxmsgsiz(rawInfo),
                    maxCredentialCountInList: fido_cbor_info_maxcredcntlst(rawInfo),
                    maxCredentialIdLength: fido_cbor_info_maxcredidlen(rawInfo),
                    maxCredentialBlobLength: fido_cbor_info_maxcredbloblen(rawInfo),
                    maxLargeBlob: fido_cbor_info_maxlargeblob(rawInfo),
                    maxRPIDsForMinPINLength: fido_cbor_info_maxrpid_minpinlen(rawInfo)),
                // Zero is what a key reports when it enforces no minimum of its own, and
                // zero as a minimum PIN length would let an empty PIN through the UI.
                minPINLength: minPIN > 0 ? Int(minPIN) : nil,
                forcePINChange: fido_cbor_info_new_pin_required(rawInfo),
                remainingResidentKeys: rkRemaining >= 0 ? Int(rkRemaining) : nil,
                uvAttempts: uvAttempts > 0 ? uvAttempts : nil,
                uvModalities: AuthenticatorInfo.uvModalityNames(fido_cbor_info_uv_modality(rawInfo)))
        }
    }

    // MARK: - Inventory

    func inventory(devicePath: String, pin: String) throws -> CredentialInventory {
        guard !pin.isEmpty else {
            throw FidoPassError.invalidState("A PIN is required to list credentials on the key")
        }

        // One open for the whole read. Enumerating the relying parties and then each party's
        // credentials in separate opens would seize and release the key once per party, and
        // for the duration of each nothing else on the machine can use it.
        return try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            guard fido_dev_supports_credman(device) else {
                throw FidoPassError.unsupported("This key does not support credential management")
            }

            let metadata = Self.readMetadata(device: device, pin: pin)
            let parties = try Self.readRelyingParties(device: device, pin: pin)

            var groups: [CredentialInventory.RelyingParty] = []
            var unreadable: [String: String] = [:]
            for party in parties {
                do {
                    let credentials = try Self.readCredentials(device: device, rpId: party.id, pin: pin)
                    groups.append(CredentialInventory.RelyingParty(id: party.id,
                                                                   name: party.name,
                                                                   idHashHex: party.idHashHex,
                                                                   credentials: credentials))
                } catch {
                    // One unreadable relying party must not blank the rest: a partial
                    // inventory that says which part is missing beats no inventory at all.
                    unreadable[party.id] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    groups.append(CredentialInventory.RelyingParty(id: party.id,
                                                                   name: party.name,
                                                                   idHashHex: party.idHashHex,
                                                                   credentials: []))
                }
            }

            return CredentialInventory(relyingParties: groups,
                                       residentKeysUsed: metadata.used,
                                       residentKeysRemaining: metadata.remaining,
                                       largeBlobArrayBytes: Self.largeBlobArraySize(device: device),
                                       unreadableRelyingParties: unreadable)
        }
    }

    /// Slot counts for the whole key. Best-effort: a key that declines to report them still
    /// has an enumerable credential list, and losing the counts must not lose the list.
    private static func readMetadata(device: OpaquePointer, pin: String) -> (used: Int?, remaining: Int?) {
        guard let raw = fido_credman_metadata_new() else { return (nil, nil) }
        var metadata: OpaquePointer? = raw
        defer { fido_credman_metadata_free(&metadata) }

        let rc = PinScope.withPIN(pin) { fido_credman_get_dev_metadata(device, raw, $0) }
        guard rc == FIDO_OK else { return (nil, nil) }
        return (Int(fido_credman_rk_existing(raw)), Int(fido_credman_rk_remaining(raw)))
    }

    private struct PartyHeader {
        let id: String
        let name: String?
        let idHashHex: String
    }

    private static func readRelyingParties(device: OpaquePointer, pin: String) throws -> [PartyHeader] {
        guard let raw = fido_credman_rp_new() else {
            throw FidoPassError.invalidState("credman_rp_new")
        }
        var parties: OpaquePointer? = raw
        defer { fido_credman_rp_free(&parties) }

        let rc = PinScope.withPIN(pin) { fido_credman_get_dev_rp(device, raw, $0) }
        // A key holding nothing reports it as an error rather than as an empty list.
        if rc == FIDO_ERR_NO_CREDENTIALS { return [] }
        try checkCredman(rc, operation: "credman_get_dev_rp")

        let count = fido_credman_rp_count(raw)
        var headers: [PartyHeader] = []
        headers.reserveCapacity(count)
        for index in 0..<count {
            guard let rawId = fido_credman_rp_id(raw, index) else { continue }
            let hashLength = fido_credman_rp_id_hash_len(raw, index)
            let hash: String
            if hashLength > 0, let hashPointer = fido_credman_rp_id_hash_ptr(raw, index) {
                hash = UnsafeBufferPointer(start: hashPointer, count: hashLength)
                    .map { String(format: "%02x", $0) }.joined()
            } else {
                hash = ""
            }
            // Keys seen so far return no relying-party name even when one was supplied at
            // creation, so an empty name is normal and must not read as a blank row.
            let name = fido_credman_rp_name(raw, index).map { String(cString: $0) }
            headers.append(PartyHeader(id: String(cString: rawId),
                                       name: (name?.isEmpty ?? true) ? nil : name,
                                       idHashHex: hash))
        }
        return headers
    }

    private static func readCredentials(device: OpaquePointer, rpId: String, pin: String) throws -> [ResidentCredential] {
        guard let raw = fido_credman_rk_new() else {
            throw FidoPassError.invalidState("credman_rk_new")
        }
        var residentKeys: OpaquePointer? = raw
        defer { fido_credman_rk_free(&residentKeys) }

        let rc = PinScope.withPIN(pin) { fido_credman_get_dev_rk(device, rpId, raw, $0) }
        if rc == FIDO_ERR_NO_CREDENTIALS { return [] }
        try checkCredman(rc, operation: "credman_get_dev_rk")

        let count = fido_credman_rk_count(raw)
        var credentials: [ResidentCredential] = []
        credentials.reserveCapacity(count)
        for index in 0..<count {
            guard let credential = fido_credman_rk(raw, index),
                  let idPointer = fido_cred_id_ptr(credential) else { continue }

            let credentialId = Data(bytes: idPointer, count: fido_cred_id_len(credential))
            let userIdLength = fido_cred_user_id_len(credential)
            let userId: Data
            if userIdLength > 0, let userIdPointer = fido_cred_user_id_ptr(credential) {
                userId = Data(bytes: userIdPointer, count: userIdLength)
            } else {
                userId = Data()
            }

            let publicKeyLength = fido_cred_pubkey_len(credential)
            let publicKey: Data?
            if publicKeyLength > 0, let publicKeyPointer = fido_cred_pubkey_ptr(credential) {
                publicKey = Data(bytes: publicKeyPointer, count: publicKeyLength)
            } else {
                publicKey = nil
            }

            let rawName = fido_cred_user_name(credential).map { String(cString: $0) }
            let rawDisplay = fido_cred_display_name(credential).map { String(cString: $0) }
            let coseType = fido_cred_type(credential)

            credentials.append(ResidentCredential(
                // From the loop, never `fido_cred_rp_id`: that returns NULL for a credential
                // obtained through credential management.
                rpId: rpId,
                credentialIdB64: credentialId.base64EncodedString(),
                userIdHex: userId.map { String(format: "%02x", $0) }.joined(),
                userIdUTF8: ResidentCredential.readableText(from: userId),
                userName: CredentialUserName.classify(rawName: rawName, rpId: rpId),
                userDisplayName: (rawDisplay?.isEmpty ?? true) ? nil : rawDisplay,
                coseAlgorithm: coseType == 0 ? nil : Int(coseType),
                publicKeyB64: publicKey?.base64EncodedString(),
                credentialProtection: CredentialProtection(rawValue: Int(fido_cred_prot(credential))),
                hasLargeBlobKey: fido_cred_largeblob_key_len(credential) > 0))
        }
        return credentials
    }

    /// Size of the serialized large-blob array. Needs no PIN, and its contents are never read.
    private static func largeBlobArraySize(device: OpaquePointer) -> Int? {
        var buffer: UnsafeMutablePointer<UInt8>?
        var length: size_t = 0
        let rc = fido_dev_largeblob_get_array(device, &buffer, &length)
        defer { if let buffer { free(buffer) } }
        guard rc == FIDO_OK else { return nil }
        return Int(length)
    }

    /// Turns the two "this key is too old for credential management" codes into a message
    /// that says so, instead of a raw libfido2 status.
    private static func checkCredman(_ rc: Int32, operation: String) throws {
        if rc == FIDO_ERR_INVALID_COMMAND || rc == FIDO_ERR_UNSUPPORTED_OPTION {
            throw FidoPassError.unsupported("This key does not support credential management")
        }
        try Libfido2Context.check(rc, operation: operation)
    }

    // MARK: - cbor_info readers

    private static func strings(_ pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                count: size_t) -> [String] {
        guard let pointer, count > 0 else { return [] }
        var values: [String] = []
        values.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let raw = pointer.advanced(by: index).pointee else { continue }
            values.append(String(cString: raw))
        }
        return values
    }

    private static func options(in info: OpaquePointer?) -> [AuthenticatorInfo.Option] {
        let count = fido_cbor_info_options_len(info)
        guard count > 0,
              let names = fido_cbor_info_options_name_ptr(info),
              let values = fido_cbor_info_options_value_ptr(info) else { return [] }
        var options: [AuthenticatorInfo.Option] = []
        options.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let raw = names.advanced(by: index).pointee else { continue }
            options.append(AuthenticatorInfo.Option(name: String(cString: raw),
                                                    value: values.advanced(by: index).pointee))
        }
        return options
    }

    private static func pinProtocols(in info: OpaquePointer?) -> [Int] {
        let count = fido_cbor_info_protocols_len(info)
        guard count > 0, let pointer = fido_cbor_info_protocols_ptr(info) else { return [] }
        return UnsafeBufferPointer(start: pointer, count: Int(count)).map(Int.init)
    }

    private static func algorithms(in info: OpaquePointer?) -> [AuthenticatorInfo.Algorithm] {
        let count = fido_cbor_info_algorithm_count(info)
        guard count > 0 else { return [] }
        var algorithms: [AuthenticatorInfo.Algorithm] = []
        algorithms.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let cose = fido_cbor_info_algorithm_cose(info, size_t(index))
            let type = fido_cbor_info_algorithm_type(info, size_t(index)).map { String(cString: $0) } ?? "public-key"
            algorithms.append(AuthenticatorInfo.Algorithm(cose: Int(cose), type: type))
        }
        return algorithms
    }

    private static func certifications(in info: OpaquePointer?) -> [AuthenticatorInfo.Certification] {
        let count = fido_cbor_info_certs_len(info)
        guard count > 0,
              let names = fido_cbor_info_certs_name_ptr(info),
              let values = fido_cbor_info_certs_value_ptr(info) else { return [] }
        var certifications: [AuthenticatorInfo.Certification] = []
        certifications.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let raw = names.advanced(by: index).pointee else { continue }
            certifications.append(AuthenticatorInfo.Certification(name: String(cString: raw),
                                                                  value: values.advanced(by: index).pointee))
        }
        return certifications
    }

    /// The 16-byte model identifier, hex-encoded. Not an identity — see `DeviceStatus.aaguid`.
    private static func aaguid(in info: OpaquePointer?) -> String? {
        let length = fido_cbor_info_aaguid_len(info)
        guard length > 0, let pointer = fido_cbor_info_aaguid_ptr(info) else { return nil }
        let bytes = UnsafeBufferPointer(start: pointer, count: length)
        // All zeroes is how a key declines to identify its model.
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
