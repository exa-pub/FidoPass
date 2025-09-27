import SwiftUI
import FidoPassCore

enum DeviceColorPalette {
    private static let palette: [Color] = [
        Color(red: 0.96, green: 0.36, blue: 0.33),
        Color(red: 0.99, green: 0.67, blue: 0.28),
        Color(red: 0.39, green: 0.73, blue: 0.37),
        Color(red: 0.30, green: 0.63, blue: 0.87),
        Color(red: 0.59, green: 0.49, blue: 0.84),
        Color(red: 0.94, green: 0.55, blue: 0.74),
        Color(red: 0.38, green: 0.66, blue: 0.79),
        Color(red: 0.89, green: 0.53, blue: 0.33)
    ]

    static func color(for device: FidoDevice) -> Color {
        let seed = device.identitySeed.lowercased()
        var hash: UInt64 = 1469598103934665603
        for scalar in seed.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1099511628211
        }
        let index = Int(hash % UInt64(palette.count))
        return palette[index]
    }
}
