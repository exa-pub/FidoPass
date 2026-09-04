import XCTest
import AppKit
@testable import FidoPassAppKit

@MainActor
final class SecretTextViewTests: AppTestCase {
    func testFailedCopyDoesNotClaimOwnershipOrDeleteSelectedText() {
        let board = MemoryPasteboard()
        board.acceptsWrites = false
        let clipboard = ClipboardService(pasteboard: board)
        let view = SecretTextView()
        view.clipboard = clipboard
        view.isEditable = true
        view.string = "synthetic"
        view.setSelectedRange(NSRange(location: 0, length: 9))
        view.cut(nil)
        XCTAssertEqual(view.string, "synthetic")
        XCTAssertFalse(clipboard.lastWriteSucceeded)
        let count = board.changeCount
        clipboard.clearIfOwned()
        XCTAssertEqual(board.changeCount, count)
    }

    func testTextCopyAndCutUseConcealedServiceAndDisableOtherExports() {
        let board = MemoryPasteboard()
        let clipboard = ClipboardService(pasteboard: board)
        let view = SecretTextView()
        view.clipboard = clipboard
        view.isEditable = true
        view.string = "synthetic"
        view.setSelectedRange(NSRange(location: 0, length: 9))
        view.copy(nil)
        XCTAssertTrue(clipboard.lastWriteSucceeded)
        XCTAssertNil(view.validRequestor(forSendType: .string, returnType: nil))
        XCTAssertFalse(view.writeSelection(to: .general, type: .string))
        XCTAssertFalse(view.writeSelection(to: .general, types: [.string]))
        view.cut(nil)
        XCTAssertTrue(view.string.isEmpty)
        clipboard.clearIfOwned()
    }

    func testClearingTextAlsoRemovesUndoActions() {
        let view = SecretTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.allowsUndo = true
        view.string = "synthetic"
        view.undoManager?.registerUndo(withTarget: view) { $0.string = "synthetic" }
        view.clearIncludingUndoHistory()
        view.undoManager?.undo()
        XCTAssertTrue(view.string.isEmpty)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
        window.contentView = nil
    }
}
