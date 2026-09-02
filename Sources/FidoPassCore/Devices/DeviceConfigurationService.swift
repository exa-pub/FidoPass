import Foundation
import CLibfido2

/// CTAP 2.1 `authenticatorConfig`, the four settings a key lets you change about itself.
///
/// Each is one libfido2 call plus the same two pieces of care: the PIN goes through
/// `PinScope` so it is wiped, and a key that does not support the subcommand says so in
/// words rather than as a raw status code. A key answers `FIDO_ERR_INVALID_COMMAND` or
/// `UNSUPPORTED_OPTION` for a subcommand it does not have, and "0x01" tells a user nothing.
final class DeviceConfigurationService: DeviceConfiguring, @unchecked Sendable {

    private let deviceRepository: DeviceRepositoryProtocol

    init(deviceRepository: DeviceRepositoryProtocol) {
        self.deviceRepository = deviceRepository
    }

    @discardableResult
    func toggleAlwaysUV(devicePath: String, pin: String) throws -> Bool {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            let rc = PinScope.withPIN(pin) { fido_dev_toggle_always_uv(device, $0) }
            try Self.check(rc, setting: "always require user verification")

            // The request says "flip", not "set to true", so the new state is whatever the
            // key now reports — asking is the only way to know which way it went.
            guard let rawInfo = fido_cbor_info_new() else {
                throw FidoPassError.invalidState("cbor_info_new")
            }
            var info: OpaquePointer? = rawInfo
            defer { fido_cbor_info_free(&info) }
            try Libfido2Context.check(fido_dev_get_cbor_info(device, rawInfo), operation: "get_cbor_info")
            return Self.option(named: "alwaysUv", in: rawInfo) ?? false
        }
    }

    func setMinimumPINLength(devicePath: String, length: Int, pin: String) throws {
        guard length >= PinPolicy.ctapFloor else {
            throw FidoPassError.invalidState("The minimum PIN length cannot go below \(PinPolicy.ctapFloor)")
        }
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            let rc = PinScope.withPIN(pin) { fido_dev_set_pin_minlen(device, size_t(length), $0) }
            // Verified on hardware: a value equal to the current minimum is accepted and
            // changes nothing, so only a decrease is actually refused. Said plainly, because
            // "invalid parameter" reads like a bug in the app rather than a rule of the key.
            if rc == FIDO_ERR_INVALID_PARAMETER {
                throw FidoPassError.invalidState("The key refused this length. The minimum can only be raised, never lowered.")
            }
            try Self.check(rc, setting: "minimum PIN length")
        }
    }

    func forcePINChange(devicePath: String, pin: String) throws {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            let rc = PinScope.withPIN(pin) { fido_dev_force_pin_change(device, $0) }
            try Self.check(rc, setting: "force PIN change")
        }
    }

    func enableEnterpriseAttestation(devicePath: String, pin: String) throws {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            let rc = PinScope.withPIN(pin) { fido_dev_enable_entattest(device, $0) }
            try Self.check(rc, setting: "enterprise attestation")
        }
    }

    private static func check(_ rc: Int32, setting: String) throws {
        if rc == FIDO_ERR_INVALID_COMMAND || rc == FIDO_ERR_UNSUPPORTED_OPTION {
            throw FidoPassError.unsupported("This key cannot change ‘\(setting)’")
        }
        try Libfido2Context.check(rc, operation: "config: \(setting)")
    }

    private static func option(named name: String, in info: OpaquePointer?) -> Bool? {
        let count = fido_cbor_info_options_len(info)
        guard let names = fido_cbor_info_options_name_ptr(info),
              let values = fido_cbor_info_options_value_ptr(info) else { return nil }
        for index in 0..<Int(count) {
            guard let raw = names.advanced(by: index).pointee else { continue }
            if String(cString: raw) == name { return values.advanced(by: index).pointee }
        }
        return nil
    }
}
