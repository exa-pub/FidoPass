import XCTest
import AppKit
import SwiftUI
@testable import FidoPassAppKit

@MainActor
final class SecretTextViewTests: AppTestCase {
    func testSingleLineBackupStaysOnOneLineAndCopiesTheFullValue() throws {
        for byteCount in [32, 48] {
            let text = Data(repeating: 0xA5, count: byteCount).base64EncodedString()
            for masked in [true, false] {
                let board = MemoryPasteboard()
                let clipboard = ClipboardService(pasteboard: board)
                let host = NSHostingView(rootView:
                    PlainTextEditor(text: .constant(text), isEditable: false, monospaced: true,
                                    isMasked: masked, isSingleLine: true)
                        .environment(\.clipboard, clipboard)
                        .frame(width: 296, height: 32))
                host.frame = NSRect(x: 0, y: 0, width: 296, height: 32)
                host.layoutSubtreeIfNeeded()
                let view = try XCTUnwrap(secretText(in: host))
                let layout = try XCTUnwrap(view.layoutManager)
                let container = try XCTUnwrap(view.textContainer)
                layout.ensureLayout(for: container)
                var lines: [NSRect] = []
                layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
                    _, used, _, _, _ in lines.append(used)
                }
                XCTAssertEqual(lines.count, 1, "Backup text must not wrap, masked or revealed")
                let line = try XCTUnwrap(lines.first)
                XCTAssertLessThanOrEqual(line.height + 2 * view.textContainerInset.height, host.bounds.height)
                XCTAssertLessThanOrEqual(line.width, container.size.width)

                view.setSelectedRange(NSRange(location: 0, length: text.utf16.count))
                view.copy(nil)
                XCTAssertEqual(board.items.first?.string(forType: .string), text,
                               "Visual truncation must not truncate the clipboard value")
                view.clearIncludingUndoHistory()
                clipboard.clearIfOwned()
            }
        }
    }

    private func secretText(in view: NSView) -> SecretTextView? {
        if let text = view as? SecretTextView { return text }
        return view.subviews.lazy.compactMap { self.secretText(in: $0) }.first
    }

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
