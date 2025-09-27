import Foundation
import CLibfido2

public protocol DeviceRepositoryProtocol {
    func listDevices(limit: Int) throws -> [FidoDevice]
    func withOpenedDevice<T>(path: String?, _ body: (OpaquePointer, String) throws -> T) throws -> T
    func ensureHmacSecretSupported(_ device: OpaquePointer) throws
}
