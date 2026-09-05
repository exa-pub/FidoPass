import Foundation
import FidoPassCore

package struct VirtualDevice: Identifiable, Sendable {
    package enum Connection: String, Sendable {
        case connected = "Connected"
        case disconnected = "Disconnected"
        case disconnecting = "Disconnecting…"
        case connecting = "Connecting…"
        case stopped = "Stopped"
    }

    package let id: UUID
    package let name: String
    package let profile: OpenSKHostClient.Profile
    package let connection: Connection
    package let device: FidoDevice?
    package let touch: OpenSKHostClient.Touch?
    package let failure: VirtualKeyError?
}
