import XCTest
import AppKit
@testable import FidoPassAppKit

@MainActor
final class ClipboardServiceTests: AppTestCase {
    func testSecretIsPublishedAtomicallyWithConcealmentAndHostRestriction() throws {
        let board = MemoryPasteboard()
        let clipboard = ClipboardService(pasteboard: board)
        XCTAssertNotNil(clipboard.copySecret("synthetic"))
        XCTAssertTrue(board.options.contains(.currentHostOnly))
        let item = try XCTUnwrap(board.items.first)
        XCTAssertTrue(item.types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        XCTAssertEqual(item.string(forType: .string), "synthetic")
        _ = board.clearContents() // Another application owns the new revision.
        let count = board.changeCount
        clipboard.clearIfOwned()
        XCTAssertEqual(board.changeCount, count)
    }
}
