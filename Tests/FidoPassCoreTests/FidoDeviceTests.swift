import XCTest
@testable import FidoPassCore

final class FidoDeviceTests: XCTestCase {

    /// The signature is written to `UserDefaults` (last used account, label histories), so
    /// its format is a contract: four upper-case hex digits, a colon, four more.
    func testModelSignatureFormatIsFrozen() {
        let device = FidoDevice(path: "ioreg://1", product: "YubiKey 5", manufacturer: "Yubico",
                                vendorId: 0x1050, productId: 0x0407)
        XCTAssertEqual(device.modelSignature, "1050:0407")
    }

    /// A different path is a reconnect, not a different model.
    func testModelSignatureIgnoresThePath() {
        let one = FidoDevice(path: "ioreg://1", product: "K", manufacturer: "", vendorId: 1, productId: 2)
        let two = FidoDevice(path: "ioreg://2", product: "K", manufacturer: "", vendorId: 1, productId: 2)
        XCTAssertEqual(one.modelSignature, two.modelSignature)
    }
}
