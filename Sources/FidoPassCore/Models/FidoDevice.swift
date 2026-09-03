import Foundation

public struct FidoDevice: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let product: String
    public let manufacturer: String
    public let vendorId: Int
    public let productId: Int

    public init(path: String,
                product: String,
                manufacturer: String,
                vendorId: Int,
                productId: Int) {
        self.path = path
        self.product = product
        self.manufacturer = manufacturer
        self.vendorId = vendorId
        self.productId = productId
    }

    public var displayName: String {
        DeviceLabelFormatter.displayName(for: self)
    }

    public var identityLabel: String {
        DeviceLabelFormatter.identityLabel(for: self)
    }

    public var identitySeed: String {
        DeviceLabelFormatter.identitySeed(for: self)
    }

    /// Vendor and product ids as one string — a *model*, never an individual key.
    ///
    /// Two keys of the same model share it, and changing the enabled interfaces on one key
    /// changes it. Used where a stable but imprecise name for "which key" is acceptable:
    /// preselecting the last used account, and naming the key a label history was written on.
    /// The format is persisted in `UserDefaults`, so it is frozen.
    public var modelSignature: String {
        String(format: "%04X:%04X", vendorId, productId)
    }
}
