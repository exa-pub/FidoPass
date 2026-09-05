import Foundation
import FidoPassCore

package struct VirtualDeviceSnapshot: Sendable {
    package let revision: UInt64
    package let devices: [VirtualDevice]
    package var connectedDevices: [FidoDevice] { devices.compactMap(\.device) }
}
