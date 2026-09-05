import Foundation
import CLibfido2

final class DeviceRepository: DeviceAccessing, Sendable {
    /// More keys than this on one Mac is not a case worth handling.
    private static let manifestLimit = 16
    private let connectionFactory: (any DeviceConnectionFactory)?
    private let injectedLister: (any DeviceListing)?

    init(connectionFactory: (any DeviceConnectionFactory)? = nil, deviceLister: (any DeviceListing)? = nil) {
        self.connectionFactory = connectionFactory
        self.injectedLister = deviceLister
        Libfido2Context.initialize()
    }

    func listDevices() throws -> [FidoDevice] {
        if let injectedLister { return try injectedLister.listDevices() }
        guard connectionFactory == nil else {
            throw FidoPassError.invalidState("An injected transport requires an explicit device list")
        }
        let limit = Self.manifestLimit
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

    func withOpenedDevice<T>(path: String, _ body: (OpaquePointer, String) throws -> T) throws -> T {
        guard let device = fido_dev_new() else {
            throw FidoPassError.invalidState("fido_dev_new")
        }
        defer {
            fido_dev_close(device)
            var dev: OpaquePointer? = device
            fido_dev_free(&dev)
        }

        // Every synchronous call has a finite deadline, including open and non-reset work.
        try Libfido2Context.check(fido_dev_set_timeout(device, 35_000), operation: "set_timeout")
        if let connectionFactory {
            return try LibfidoTransportBridge.withConfiguredDevice(device, connection: connectionFactory.connect(path: path)) { token in
                try Libfido2Context.check(fido_dev_open(device, token), operation: "open injected device")
                return try body(device, path)
            }
        }
        try Libfido2Context.check(fido_dev_open(device, path), operation: "open device")
        return try body(device, path)
    }

    /// Reads what the authenticator will tell us without any user interaction.
    func status(devicePath: String) throws -> DeviceStatus {
        try withOpenedDevice(path: devicePath) { device, _ in
            var retries: Int32 = -1
            let retryRC = fido_dev_get_retry_count(device, &retries)
            let remainingPINAttempts = (retryRC == FIDO_OK && retries >= 0) ? Int(retries) : nil

            return try CborInfo.with(device: device) { info in
                DeviceStatus(pinRetriesRemaining: remainingPINAttempts,
                             hasPIN: info.option("clientPin") == true,
                             supportsHmacSecret: info.hasExtension("hmac-secret"),
                             supportsLargeBlobs: info.supportsLargeBlobs,
                             remainingResidentKeys: info.remainingResidentKeys,
                             minPINLength: info.minPINLength,
                             forcePINChange: info.forcePINChange,
                             aaguid: info.aaguid,
                             supportsConfiguration: info.option("authnrCfg") == true,
                             alwaysUV: info.option("alwaysUv"))
            }
        }
    }

    func aaguid(of device: OpaquePointer) throws -> String? {
        try CborInfo.with(device: device) { $0.aaguid }
    }

    func ensureHmacSecretSupported(_ device: OpaquePointer) throws {
        guard try CborInfo.with(device: device, { $0.hasExtension("hmac-secret") }) else {
            throw FidoPassError.unsupported("Authenticator does not support hmac-secret")
        }
    }
}
