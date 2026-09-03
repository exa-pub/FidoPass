import XCTest
import CryptoKit
@testable import FidoPassCore

/// The emoji table is part of the `keyv1` format: reorder one entry and every fingerprint
/// ever shown changes. These tests pin the whole table, not just its shape.
final class EmojiAlphabetTests: XCTestCase {

    func testHasExactly256DistinctSingleScalarEmoji() {
        let scalars = EmojiAlphabet.scalars
        XCTAssertEqual(scalars.count, 256)
        XCTAssertEqual(EmojiAlphabet.count, 256)
        XCTAssertEqual(Set(scalars).count, 256, "a repeated entry would make two byte values look alike")
        for scalar in scalars {
            XCTAssertTrue(scalar.properties.isEmoji, "\(scalar) is not an emoji")
        }
    }

    /// The table is `andrew-d/emoji256` in README order — first row, last row, and a hash of
    /// everything in between.
    func testMatchesTheEmoji256Table() {
        let text = String(String.UnicodeScalarView(EmojiAlphabet.scalars))
        XCTAssertTrue(text.hasPrefix("👍👎👊✌✋👌👏👋"))
        XCTAssertTrue(text.hasSuffix("🎵🎺🎿🏋🏭👅👀👯"))
        XCTAssertEqual(Data(SHA256.hash(data: Data(text.utf8))).hexString,
                       "46d5672e8e5a6a2d54c7d5a720d36368b0b842ee8324631a37b83066a6303d92")
    }

    /// 44 entries have no emoji presentation of their own and would draw as text glyphs.
    func testEntriesWithoutEmojiPresentationGetTheVariationSelector() {
        let textual = EmojiAlphabet.scalars.enumerated().filter { !$0.element.properties.isEmojiPresentation }
        XCTAssertEqual(textual.count, 44)
        for (index, scalar) in textual {
            let shown = EmojiAlphabet.displayString(for: UInt8(index))
            XCTAssertEqual(Array(shown.unicodeScalars), [scalar, "\u{FE0F}"], "\(scalar) needs U+FE0F to render as emoji")
        }
        let emojiPresentation = EmojiAlphabet.scalars.enumerated().first { $0.element.properties.isEmojiPresentation }!
        XCTAssertEqual(EmojiAlphabet.displayString(for: UInt8(emojiPresentation.offset)),
                       String(emojiPresentation.element),
                       "an entry that already renders as emoji gets nothing added")
    }

    func testEveryByteHasADisplayString() {
        let shown = (0...255).map { EmojiAlphabet.displayString(for: UInt8($0)) }
        XCTAssertEqual(Set(shown).count, 256)
        for text in shown {
            XCTAssertEqual(text.count, 1, "\(text) should be one grapheme")
        }
    }
}
