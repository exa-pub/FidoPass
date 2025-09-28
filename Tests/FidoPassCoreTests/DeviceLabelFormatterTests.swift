import XCTest
@testable import FidoPassCore

final class DeviceLabelFormatterTests: XCTestCase {
    func testDisplayNameFallsBackToPathWhenMetadataEmpty() {
        let device = FidoDevice(path: "/dev/usb",
                                product: "   ",
                                manufacturer: "",
                                vendorId: 0x1234,
                                productId: 0x5678)
        XCTAssertEqual(DeviceLabelFormatter.displayName(for: device), "/dev/usb")
    }

    func testConciseNameAvoidsRepeatingManufacturer() {
        let device = FidoDevice(path: "/dev/yubikey",
                                product: "YubiKey 5C NFC",
                                manufacturer: "YubiKey",
                                vendorId: 0x1050,
                                productId: 0x0407)
        XCTAssertEqual(DeviceLabelFormatter.conciseName(for: device), "YubiKey")
    }

    func testIdentityLabelUsesUsbLocationWhenPresent() {
        let device = FidoDevice(path: "/dev/usb@0x1234abcd",
                                product: "Key",
                                manufacturer: "Vendor",
                                vendorId: 0x0111,
                                productId: 0x0222)
        let label = DeviceLabelFormatter.identityLabel(for: device)
        XCTAssertEqual(label, "VID 0111 PID 0222 @1234ABCD")
    }

    func testIdentityLabelFallsBackToHashWhenLocationMissing() {
        let device = FidoDevice(path: "/dev/path",
                                product: "Key",
                                manufacturer: "Vendor",
                                vendorId: 0x0AAA,
                                productId: 0x0BBB)
        let label = DeviceLabelFormatter.identityLabel(for: device)
        XCTAssertTrue(label.hasPrefix("VID 0AAA PID 0BBB #"))
        XCTAssertEqual(label.count, "VID 0AAA PID 0BBB #FFFFFF".count)
    }

    func testIdentitySeedIgnoresCaseInPath() {
        let lowerPath = "/dev/usb@0x10"
        let upperPath = "/DEV/USB@0x10"
        let upper = FidoDevice(path: upperPath,
                                product: "",
                                manufacturer: "",
                                vendorId: 0,
                                productId: 0)
        let lower = FidoDevice(path: lowerPath,
                                product: "",
                                manufacturer: "",
                                vendorId: 0,
                                productId: 0)
        XCTAssertEqual(DeviceLabelFormatter.identitySeed(for: upper), DeviceLabelFormatter.identitySeed(for: lower))
    }
}
