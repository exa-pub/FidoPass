import Foundation

/// Optional raw HID seam. The default libfido2 framing remains in charge in this mode.
package protocol DeviceHIDConnection: DeviceTransportConnection {
    var usesHIDReports: Bool { get }
    func writeReport(_ report: Data) throws
    func readReport(capacity: Int, timeoutMilliseconds: Int) throws -> Data
}
