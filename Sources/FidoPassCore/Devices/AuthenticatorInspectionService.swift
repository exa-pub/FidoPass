import Foundation
import CLibfido2

/// Reads an authenticator wide rather than deep: everything `getInfo` reports, and every
/// resident credential credential management will list.
///
/// Lives beside `DeviceManagementService` rather than inside `DeviceRepository` for the same
/// reason that one does: the repository is device access, this is an operation performed
/// because a person asked. Nothing here writes to the key.
final class AuthenticatorInspectionService: AuthenticatorInspecting, Sendable {

    private let deviceRepository: DeviceAccessing

    init(deviceRepository: DeviceAccessing) {
        self.deviceRepository = deviceRepository
    }

    // MARK: - Self-description

    func inspect(devicePath: String) throws -> AuthenticatorInfo {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            var pinRetries: Int32 = -1
            let pinRC = fido_dev_get_retry_count(device, &pinRetries)
            var uvRetries: Int32 = -1
            let uvRC = fido_dev_get_uv_retry_count(device, &uvRetries)

            let flags = fido_dev_flags(device)
            var capabilities: [String] = []
            if flags & UInt8(FIDO_CAP_WINK) != 0 { capabilities.append("wink") }
            if flags & UInt8(FIDO_CAP_CBOR) != 0 { capabilities.append("cbor") }
            // NMSG is inverted: the bit means the device does *not* speak CTAP1 messages.
            if flags & UInt8(FIDO_CAP_NMSG) == 0 { capabilities.append("msg") }

            return try CborInfo.with(device: device) { info in
                AuthenticatorInfo(
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
                    versions: info.versions,
                    extensions: info.extensions,
                    options: info.options,
                    aaguid: info.aaguid,
                    pinProtocols: info.pinProtocols,
                    algorithms: info.algorithms,
                    transports: info.transports,
                    certifications: info.certifications,
                    firmwareVersion: info.firmwareVersion,
                    limits: info.limits,
                    minPINLength: info.minPINLength,
                    forcePINChange: info.forcePINChange,
                    remainingResidentKeys: info.remainingResidentKeys,
                    uvAttempts: info.uvAttempts,
                    uvModalities: AuthenticatorInfo.uvModalityNames(info.uvModality))
            }
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
        try Libfido2Context.checkCredman(rc, operation: "credman_get_dev_rp")

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
        try Libfido2Context.checkCredman(rc, operation: "credman_get_dev_rk")

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
            let largeBlobKey = LargeBlobStore.key(of: credential)

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
                hasLargeBlobKey: largeBlobKey != nil,
                record: recordState(device: device, rpId: rpId, largeBlobKey: largeBlobKey)))
        }
        return credentials
    }

    /// The state of a v2 account's record — read for FidoPass's v2 credentials only, and
    /// only as a state: the record's mask is key material and stays in the core.
    private static func recordState(device: OpaquePointer, rpId: String, largeBlobKey: Data?) -> ResidentCredential.RecordState? {
        guard AccountFormat.parse(rpId: rpId)?.format == .v2 else { return nil }
        guard let largeBlobKey,
              let blob = try? LargeBlobStore.read(device: device, key: largeBlobKey) else { return .missing }
        guard let record = AccountRecord(decoding: blob) else { return .corrupt }
        return record.kind == .portable ? .portable : .local
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
}
