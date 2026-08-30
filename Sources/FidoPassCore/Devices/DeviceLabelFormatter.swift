import Foundation
import CryptoKit

enum DeviceLabelFormatter {
    static func displayName(for device: FidoDevice) -> String {
        let combined = device.manufacturer.isEmpty ? device.product : "\(device.manufacturer) \(device.product)"
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? device.path : trimmed
    }

    static func identityLabel(for device: FidoDevice) -> String {
        identityLabel(path: device.path, vendorId: device.vendorId, productId: device.productId)
    }

    static func identitySeed(for device: FidoDevice) -> String {
        identitySeed(path: device.path, vendorId: device.vendorId, productId: device.productId)
    }

    private static func identityLabel(path: String, vendorId: Int, productId: Int) -> String {
        let vidHex = String(format: "%04X", vendorId)
        let pidHex = String(format: "%04X", productId)
        if let location = locationId(from: path) {
            let locationHex = String(format: "%08X", location)
            return "VID \(vidHex) PID \(pidHex) @\(locationHex)"
        }
        let hash = shortHash(from: path)
        return "VID \(vidHex) PID \(pidHex) #\(hash)"
    }

    private static func identitySeed(path: String, vendorId: Int, productId: Int) -> String {
        if let location = locationId(from: path) {
            return String(format: "%08X", location)
        }
        return "\(vendorId):\(productId):\(path)"
    }

    private static func locationId(from path: String) -> Int? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "@0x") {
            let hexSlice = trimmed[range.upperBound...].prefix { $0.isHexDigit }
            if !hexSlice.isEmpty { return Int(hexSlice, radix: 16) }
        }
        if let range = trimmed.range(of: "@") {
            let decimalSlice = trimmed[range.upperBound...].prefix { $0.isNumber }
            if !decimalSlice.isEmpty { return Int(decimalSlice, radix: 10) }
        }
        return nil
    }

    private static func shortHash(from string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        let prefix = digest.prefix(3)
        return prefix.map { String(format: "%02X", $0) }.joined()
    }
}
