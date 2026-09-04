import AppKit

/// Secret text has one outbound path. Drag-and-drop and Services cannot export it through
/// NSTextView's ordinary unmarked pasteboard writers, even while the glyphs are masked.
@MainActor
final class SecretTextView: NSTextView {
    weak var clipboard: ClipboardService?

    override func copy(_ sender: Any?) {
        _ = copySelection()
    }

    override func cut(_ sender: Any?) {
        guard isEditable, copySelection() else { return }
        insertText("", replacementRange: selectedRange())
    }

    private func copySelection() -> Bool {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length, let clipboard else { return false }
        clipboard.copySecret((string as NSString).substring(with: range))
        return clipboard.lastWriteSucceeded
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { false }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? { nil }
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }
}
