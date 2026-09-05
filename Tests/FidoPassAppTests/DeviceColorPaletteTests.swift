import XCTest
import SwiftUI
@testable import FidoPassAppKit
import FidoPassCore
import AppKit

final class DeviceColorPaletteTests: AppTestCase {
    func testColorDeterminismForSameDevice() {
        let device = FidoDevice(path: "/dev/key",
                                product: "Key",
                                manufacturer: "Vendor",
                                vendorId: 1,
                                productId: 2)
        let color1 = DeviceColorPalette.color(for: device)
        let color2 = DeviceColorPalette.color(for: device)
        assertEqual(color1, color2)
    }

    func testColorIgnoresPathCase() {
        let lower = FidoDevice(path: "/dev/key",
                                product: "Key",
                                manufacturer: "Vendor",
                                vendorId: 1,
                                productId: 2)
        let upper = FidoDevice(path: "/DEV/KEY",
                                product: "Key",
                                manufacturer: "Vendor",
                                vendorId: 1,
                                productId: 2)
        assertEqual(DeviceColorPalette.color(for: lower),
                    DeviceColorPalette.color(for: upper))
    }

    func testDifferentDevicesYieldDifferentColors() {
        let deviceA = FidoDevice(path: "/dev/a",
                                  product: "A",
                                  manufacturer: "Vendor",
                                  vendorId: 1,
                                  productId: 2)
        let deviceB = FidoDevice(path: "/dev/b",
                                  product: "B",
                                  manufacturer: "Vendor",
                                  vendorId: 1,
                                  productId: 3)
        let compA = components(DeviceColorPalette.color(for: deviceA))
        let compB = components(DeviceColorPalette.color(for: deviceB))
        XCTAssertFalse(approximatelyEqual(compA.red, compB.red))
    }

    private func components(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let converted = NSColor(color).usingColorSpace(.deviceRGB)!
        return (converted.redComponent, converted.greenComponent, converted.blueComponent, converted.alphaComponent)
    }

    private func assertEqual(_ lhs: Color, _ rhs: Color, tolerance: CGFloat = 0.0001, file: StaticString = #filePath, line: UInt = #line) {
        let left = components(lhs)
        let right = components(rhs)
        XCTAssertTrue(approximatelyEqual(left.red, right.red, tolerance: tolerance) &&
                      approximatelyEqual(left.green, right.green, tolerance: tolerance) &&
                      approximatelyEqual(left.blue, right.blue, tolerance: tolerance) &&
                      approximatelyEqual(left.alpha, right.alpha, tolerance: tolerance),
                      "Colors differ", file: file, line: line)
    }

    private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
