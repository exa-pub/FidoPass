import Foundation
import CLibfido2

/// CTAP 2.1 settings with scoped PIN buffers and explicit unsupported-command errors.
final class DeviceConfigurationService: DeviceConfiguring, Sendable {

    private let deviceRepository: DeviceAccessing

    init(deviceRepository: DeviceAccessing) {
        self.deviceRepository = deviceRepository
    }

    @discardableResult
    func toggleAlwaysUV(devicePath: String, pin: String) throws -> Bool {
        try changeAlwaysUV(enabled: nil, devicePath: devicePath, pin: pin).enabled
    }

    func setAlwaysUV(enabled: Bool, devicePath: String, pin: String) throws -> AlwaysUVChange {
        try changeAlwaysUV(enabled: enabled, devicePath: devicePath, pin: pin)
    }

    private func changeAlwaysUV(enabled: Bool?, devicePath: String, pin: String) throws -> AlwaysUVChange {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            try Libfido2Context.check(fido_dev_set_timeout(device, 5_000), operation: "config timeout")
            let previous = try Self.alwaysUV(on: device)
            let target = enabled ?? !previous
            guard previous != target else { return AlwaysUVChange(previous: previous, enabled: previous) }
            let rc = try PinScope.withPIN(pin) { fido_dev_toggle_always_uv(device, $0) }
            try Self.check(rc, setting: "always require user verification")
            let actual = try Self.alwaysUV(on: device)
            guard actual == target else {
                throw FidoPassError.invalidState("The key did not confirm the requested Require UV setting")
            }
            return AlwaysUVChange(previous: previous, enabled: actual)
        }
    }

    private static func alwaysUV(on device: OpaquePointer) throws -> Bool {
        try CborInfo.with(device: device) { info in
            guard info.option("authnrCfg") == true, let enabled = info.option("alwaysUv") else {
                throw FidoPassError.unsupported("This key does not offer configurable Require UV")
            }
            return enabled
        }
    }

    func setMinimumPINLength(devicePath: String, length: Int, pin: String) throws {
        guard length >= PinPolicy.ctapFloor else {
            throw FidoPassError.invalidState("The minimum PIN length cannot go below \(PinPolicy.ctapFloor)")
        }
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            let rc = try PinScope.withPIN(pin) { fido_dev_set_pin_minlen(device, size_t(length), $0) }
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
            let rc = try PinScope.withPIN(pin) { fido_dev_force_pin_change(device, $0) }
            try Self.check(rc, setting: "force PIN change")
        }
    }

    func enableEnterpriseAttestation(devicePath: String, pin: String) throws {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            let rc = try PinScope.withPIN(pin) { fido_dev_enable_entattest(device, $0) }
            try Self.check(rc, setting: "enterprise attestation")
        }
    }

    private static func check(_ rc: Int32, setting: String) throws {
        if rc == FIDO_ERR_INVALID_COMMAND || rc == FIDO_ERR_UNSUPPORTED_OPTION {
            throw FidoPassError.unsupported("This key cannot change ‘\(setting)’")
        }
        try Libfido2Context.check(rc, operation: "config: \(setting)")
    }
}
