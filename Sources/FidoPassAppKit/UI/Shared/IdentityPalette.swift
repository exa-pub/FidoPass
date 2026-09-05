import SwiftUI
import FidoPassCore

/// One colour per identity byte, with fixed saturation and brightness.
/// The mapping is deterministic across devices; model colours use DeviceColorPalette.
enum IdentityPalette {
    static let cellCount = AccountIdentity.byteCount
    static let saturation = 0.45
    static let brightness = 0.78

    static func colors(for identity: AccountIdentity) -> [Color] {
        identity.bytes.map { byte in
            Color(hue: Double(byte) / 256, saturation: saturation, brightness: brightness)
        }
    }
}
