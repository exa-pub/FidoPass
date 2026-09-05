import AppKit
@testable import FidoPassAppKit

@MainActor
final class MemoryPasteboard: ClipboardPasteboard {
    var changeCount = 0
    var acceptsWrites = true
    var options: NSPasteboard.ContentsOptions = []
    var items: [NSPasteboardItem] = []
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        self.options = options
        return clearContents()
    }
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        guard acceptsWrites else { return false }
        items = objects.compactMap { $0 as? NSPasteboardItem }
        changeCount += 1
        return true
    }
    func clearContents() -> Int {
        items = []
        changeCount += 1
        return changeCount
    }
}
