import Foundation

public struct FidoDevice: Identifiable, Hashable, Codable {
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

    public var conciseName: String {
        DeviceLabelFormatter.conciseName(for: self)
    }

    public var identityLabel: String {
        DeviceLabelFormatter.identityLabel(for: self)
    }

    public var identitySeed: String {
        DeviceLabelFormatter.identitySeed(for: self)
    }
}
