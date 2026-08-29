import Foundation
import CLibfido2

final class DeviceRepository: DeviceRepositoryProtocol {
    func listDevices(limit: Int) throws -> [FidoDevice] {
        guard let rawList = fido_dev_info_new(limit) else {
            throw FidoPassError.noDevices
        }
        var devlist: OpaquePointer? = rawList
        defer { fido_dev_info_free(&devlist, limit) }

        var obtained = 0
        try Libfido2Context.check(fido_dev_info_manifest(devlist, limit, &obtained), operation: "dev_info_manifest")
        if obtained == 0 { return [] }

        var devices: [FidoDevice] = []
        devices.reserveCapacity(obtained)

        for index in 0..<obtained {
            guard let info = fido_dev_info_ptr(devlist, size_t(index)),
                  let cPath = fido_dev_info_path(info) else { continue }
            let path = String(cString: cPath)
            let product = fido_dev_info_product_string(info).map { String(cString: $0) } ?? "Unknown"
            let manufacturer = fido_dev_info_manufacturer_string(info).map { String(cString: $0) } ?? ""
            let vendorId = Int(fido_dev_info_vendor(info))
            let productId = Int(fido_dev_info_product(info))

            devices.append(FidoDevice(path: path,
                                      product: product,
                                      manufacturer: manufacturer,
                                      vendorId: vendorId,
                                      productId: productId))
        }
        return devices
    }

    func withOpenedDevice<T>(path providedPath: String?, _ body: (OpaquePointer, String) throws -> T) throws -> T {
        let path = try providedPath ?? firstDevicePath()
        guard let device = fido_dev_new() else {
            throw FidoPassError.invalidState("fido_dev_new")
        }
        defer {
            fido_dev_close(device)
            var dev: OpaquePointer? = device
            fido_dev_free(&dev)
        }

        try Libfido2Context.check(fido_dev_open(device, path), operation: "open \(path)")
        return try body(device, path)
    }

    /// Reads what the authenticator will tell us without any user interaction.
    ///
    /// Every field is optional-by-nature: authenticators differ in what they report, and a
    /// missing value must degrade to "unknown" rather than to a wrong number.
    func status(devicePath: String) throws -> DeviceStatus {
        try withOpenedDevice(path: devicePath) { device, _ in
            var retries: Int32 = -1
            let retryRC = fido_dev_get_retry_count(device, &retries)
            let remainingPINAttempts = (retryRC == FIDO_OK && retries >= 0) ? Int(retries) : nil

            guard let rawInfo = fido_cbor_info_new() else {
                throw FidoPassError.invalidState("cbor_info_new")
            }
            var info: OpaquePointer? = rawInfo
            defer { fido_cbor_info_free(&info) }
            try Libfido2Context.check(fido_dev_get_cbor_info(device, info), operation: "get_cbor_info")

            let rkRemaining = fido_cbor_info_rk_remaining(info)

            return DeviceStatus(pinRetriesRemaining: remainingPINAttempts,
                                hasPIN: Self.option(named: "clientPin", in: info) == true,
                                supportsHmacSecret: Self.hasExtension(named: "hmac-secret", in: info),
                                remainingResidentKeys: rkRemaining >= 0 ? Int(rkRemaining) : nil)
        }
    }

    private static func option(named name: String, in info: OpaquePointer?) -> Bool? {
        let count = fido_cbor_info_options_len(info)
        guard let names = fido_cbor_info_options_name_ptr(info),
              let values = fido_cbor_info_options_value_ptr(info) else { return nil }
        for index in 0..<count {
            guard let raw = names.advanced(by: Int(index)).pointee else { continue }
            if String(cString: raw) == name {
                return values.advanced(by: Int(index)).pointee
            }
        }
        return nil
    }

    private static func hasExtension(named name: String, in info: OpaquePointer?) -> Bool {
        let count = fido_cbor_info_extensions_len(info)
        guard let pointer = fido_cbor_info_extensions_ptr(info) else { return false }
        for index in 0..<count {
            if let raw = pointer.advanced(by: Int(index)).pointee, String(cString: raw) == name {
                return true
            }
        }
        return false
    }

    func ensureHmacSecretSupported(_ device: OpaquePointer) throws {
        guard let rawInfo = fido_cbor_info_new() else {
            throw FidoPassError.invalidState("cbor_info_new")
        }
        var info: OpaquePointer? = rawInfo
        defer { fido_cbor_info_free(&info) }

        try Libfido2Context.check(fido_dev_get_cbor_info(device, info), operation: "get_cbor_info")
        let extensionsLength = fido_cbor_info_extensions_len(info)
        guard let pointer = fido_cbor_info_extensions_ptr(info) else {
            throw FidoPassError.unsupported("extension list is unavailable")
        }
        for index in 0..<extensionsLength {
            if let ext = pointer.advanced(by: Int(index)).pointee,
               String(cString: ext) == "hmac-secret" {
                return
            }
        }
        throw FidoPassError.unsupported("Authenticator does not support hmac-secret")
    }

    private func firstDevicePath() throws -> String {
        let limit = 16
        guard let rawList = fido_dev_info_new(limit) else {
            throw FidoPassError.noDevices
        }
        var devlist: OpaquePointer? = rawList
        defer { fido_dev_info_free(&devlist, limit) }

        var obtained = 0
        try Libfido2Context.check(fido_dev_info_manifest(devlist, limit, &obtained), operation: "dev_info_manifest")
        guard obtained > 0,
              let info = fido_dev_info_ptr(devlist, 0),
              let pathPointer = fido_dev_info_path(info) else {
            throw FidoPassError.noDevices
        }
        return String(cString: pathPointer)
    }
}
