import Foundation

/// Command-level transport. A connection has one serial caller and never escapes an open.
package protocol DeviceTransportConnection: AnyObject, Sendable {
    func send(command: UInt8, payload: Data) throws
    func receive(command: UInt8, capacity: Int, timeoutMilliseconds: Int) throws -> Data
    func close()
}
