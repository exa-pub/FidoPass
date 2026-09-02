import Foundation
import CLibfido2

/// Full device access, including the raw libfido2 handle. Internal on purpose.
protocol DeviceRepositoryProtocol: DeviceListing {
    func withOpenedDevice<T>(path: String?, _ body: (OpaquePointer, String) throws -> T) throws -> T
    func ensureHmacSecretSupported(_ device: OpaquePointer) throws
    func status(devicePath: String) throws -> DeviceStatus
    /// Model identifier of an already-open device, so a caller that has one need not pay for
    /// a second open to check it. See `DeviceStatus.aaguid` for what it can and cannot prove.
    func aaguid(of device: OpaquePointer) throws -> String?
}
