import Foundation
import CLibfido2

/// One `getInfo` answer, read through libfido2's `fido_cbor_info_t`.
///
/// Every reader of the authenticator's self-description used to carry its own copy of the
/// same pointer walking — three of them for the options map alone. This is the one place
/// the C accessors are called; everything above it works with Swift values.
///
/// Every field is optional-by-nature: authenticators differ in what they report, and a
/// missing value degrades to "unknown" rather than to a wrong number.
struct CborInfo {
    private let raw: OpaquePointer

    /// Asks an open device for its `getInfo`. The C object lives for `body` and is freed
    /// afterwards, whatever happens inside.
    static func with<T>(device: OpaquePointer, _ body: (CborInfo) throws -> T) throws -> T {
        guard let raw = fido_cbor_info_new() else {
            throw FidoPassError.invalidState("cbor_info_new")
        }
        var info: OpaquePointer? = raw
        defer { fido_cbor_info_free(&info) }
        try Libfido2Context.check(fido_dev_get_cbor_info(device, raw), operation: "get_cbor_info")
        return try body(CborInfo(raw: raw))
    }

    var versions: [String] {
        Self.strings(fido_cbor_info_versions_ptr(raw), count: fido_cbor_info_versions_len(raw))
    }

    var extensions: [String] {
        Self.strings(fido_cbor_info_extensions_ptr(raw), count: fido_cbor_info_extensions_len(raw))
    }

    var transports: [String] {
        Self.strings(fido_cbor_info_transports_ptr(raw), count: fido_cbor_info_transports_len(raw))
    }

    func hasExtension(_ name: String) -> Bool {
        extensions.contains(name)
    }

    /// The `options` map as reported, unknown names included.
    var options: [AuthenticatorInfo.Option] {
        let count = fido_cbor_info_options_len(raw)
        guard count > 0,
              let names = fido_cbor_info_options_name_ptr(raw),
              let values = fido_cbor_info_options_value_ptr(raw) else { return [] }
        var options: [AuthenticatorInfo.Option] = []
        options.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let name = names.advanced(by: index).pointee else { continue }
            options.append(AuthenticatorInfo.Option(name: String(cString: name),
                                                    value: values.advanced(by: index).pointee))
        }
        return options
    }

    /// Value of a named option, or `nil` when the key never mentioned it.
    ///
    /// CTAP uses "absent" for "not implemented" and `false` for "implemented and off"; the
    /// two must not be confused, because offering a switch for the first produces a control
    /// that can only fail.
    func option(_ name: String) -> Bool? {
        options.first { $0.name == name }?.value
    }

    /// The 16-byte model identifier, hex-encoded. Not an identity — see `DeviceStatus.aaguid`.
    /// `nil` when the key reports all zeroes, which is how it declines to identify its model.
    var aaguid: String? {
        let length = fido_cbor_info_aaguid_len(raw)
        guard length > 0, let pointer = fido_cbor_info_aaguid_ptr(raw) else { return nil }
        let bytes = UnsafeBufferPointer(start: pointer, count: length)
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    var pinProtocols: [Int] {
        let count = fido_cbor_info_protocols_len(raw)
        guard count > 0, let pointer = fido_cbor_info_protocols_ptr(raw) else { return [] }
        return UnsafeBufferPointer(start: pointer, count: Int(count)).map(Int.init)
    }

    var algorithms: [AuthenticatorInfo.Algorithm] {
        let count = fido_cbor_info_algorithm_count(raw)
        guard count > 0 else { return [] }
        var algorithms: [AuthenticatorInfo.Algorithm] = []
        algorithms.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let cose = fido_cbor_info_algorithm_cose(raw, size_t(index))
            let type = fido_cbor_info_algorithm_type(raw, size_t(index)).map { String(cString: $0) } ?? "public-key"
            algorithms.append(AuthenticatorInfo.Algorithm(cose: Int(cose), type: type))
        }
        return algorithms
    }

    var certifications: [AuthenticatorInfo.Certification] {
        let count = fido_cbor_info_certs_len(raw)
        guard count > 0,
              let names = fido_cbor_info_certs_name_ptr(raw),
              let values = fido_cbor_info_certs_value_ptr(raw) else { return [] }
        var certifications: [AuthenticatorInfo.Certification] = []
        certifications.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let name = names.advanced(by: index).pointee else { continue }
            certifications.append(AuthenticatorInfo.Certification(name: String(cString: name),
                                                                  value: values.advanced(by: index).pointee))
        }
        return certifications
    }

    var firmwareVersion: UInt64 { fido_cbor_info_fwversion(raw) }

    var limits: AuthenticatorInfo.Limits {
        AuthenticatorInfo.Limits(maxMessageSize: fido_cbor_info_maxmsgsiz(raw),
                                 maxCredentialCountInList: fido_cbor_info_maxcredcntlst(raw),
                                 maxCredentialIdLength: fido_cbor_info_maxcredidlen(raw),
                                 maxCredentialBlobLength: fido_cbor_info_maxcredbloblen(raw),
                                 maxLargeBlob: fido_cbor_info_maxlargeblob(raw),
                                 maxRPIDsForMinPINLength: fido_cbor_info_maxrpid_minpinlen(raw))
    }

    /// Shortest PIN the key accepts, when it says. Zero is what a key reports when it
    /// enforces no minimum of its own, and zero as a minimum would let an empty PIN through
    /// the UI — so that reads as "not reported".
    var minPINLength: Int? {
        let declared = fido_cbor_info_minpinlen(raw)
        return declared > 0 ? Int(declared) : nil
    }

    /// The key insists the PIN be changed before it will do anything else.
    var forcePINChange: Bool { fido_cbor_info_new_pin_required(raw) }

    var remainingResidentKeys: Int? {
        let remaining = fido_cbor_info_rk_remaining(raw)
        return remaining >= 0 ? Int(remaining) : nil
    }

    var uvAttempts: UInt64? {
        let attempts = fido_cbor_info_uv_attempts(raw)
        return attempts > 0 ? attempts : nil
    }

    var uvModality: UInt64 { fido_cbor_info_uv_modality(raw) }

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
}
