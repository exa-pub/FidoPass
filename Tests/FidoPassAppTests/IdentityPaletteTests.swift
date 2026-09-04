import XCTest
import SwiftUI
@testable import FidoPassAppKit
import FidoPassCore
import AppKit

/// The strip is compared by eye between two keys, so it has to be the same function of the
/// bytes everywhere, and every cell has to be visible.
final class IdentityPaletteTests: AppTestCase {

    func testOneCellPerByte() {
        let colors = IdentityPalette.colors(for: .random())
        XCTAssertEqual(colors.count, 16)
        XCTAssertEqual(colors.count, AccountIdentity.byteCount)
    }

    func testTheSameIdentityAlwaysGetsTheSameColours() throws {
        let identity = try XCTUnwrap(AccountIdentity(hex: "00112233445566778899aabbccddeeff"))
        let first = IdentityPalette.colors(for: identity).map(components)
        let second = IdentityPalette.colors(for: identity).map(components)
        for (left, right) in zip(first, second) {
            XCTAssertEqual(left.hue, right.hue, accuracy: 0.0001)
            XCTAssertEqual(left.brightness, right.brightness, accuracy: 0.0001)
        }
    }

    /// Hue is the byte: 0x00 is red, 0x80 is halfway round the wheel. Two bytes that differ
    /// must not land on the same colour, or the strip would lie about the identity.
    func testHueFollowsTheByte() throws {
        let zero = try XCTUnwrap(AccountIdentity(bytes: Data(repeating: 0x00, count: 16)))
        let half = try XCTUnwrap(AccountIdentity(bytes: Data(repeating: 0x80, count: 16)))
        let red = components(IdentityPalette.colors(for: zero)[0])
        let cyan = components(IdentityPalette.colors(for: half)[0])
        // The hue wheel wraps: AppKit reports pure red as 1.0 as readily as 0.0.
        XCTAssertLessThan(min(red.hue, 1 - red.hue), 0.02)
        XCTAssertEqual(cyan.hue, 0.5, accuracy: 0.02)
    }

    /// Every cell is drawn at the same saturation and brightness: a dark or grey cell would
    /// read as "missing" rather than as a value.
    func testEveryCellIsLegible() throws {
        let identity = try XCTUnwrap(AccountIdentity(hex: "0010203040506070809fb0ff2a4b6c8d"))
        for color in IdentityPalette.colors(for: identity) {
            let parts = components(color)
            XCTAssertEqual(parts.brightness, IdentityPalette.brightness, accuracy: 0.03)
            XCTAssertEqual(parts.saturation, IdentityPalette.saturation, accuracy: 0.03)
        }
    }

    private func components(_ color: Color) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let converted = NSColor(color).usingColorSpace(.deviceRGB)!
        return (converted.hueComponent, converted.saturationComponent, converted.brightnessComponent)
    }
}
