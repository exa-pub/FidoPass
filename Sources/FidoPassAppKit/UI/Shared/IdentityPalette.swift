import SwiftUI
import FidoPassCore

/// The colours of an identity's fingerprint strip: one cell per byte.
///
/// Hue comes from the byte; saturation and brightness are fixed. The mapping is lossless —
/// sixteen cells carry all 128 bits — and the same on every machine, so the strip on
/// one key can be compared with the strip on another by eye. Not `DeviceColorPalette`,
/// which picks one of eight tints by hash: a fingerprint needs cells that *are* the bytes.
///
/// Muted on purpose. The strip sits in every account row; at full saturation sixteen hues
/// next to each other read as a warning stripe, and the list is not the place to shout.
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
