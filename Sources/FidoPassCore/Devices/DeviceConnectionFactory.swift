import Foundation

/// Explicit injection; an unknown path must fail, never fall back to system hardware.
package protocol DeviceConnectionFactory: Sendable {
    func connect(path: String) throws -> any DeviceTransportConnection
}
