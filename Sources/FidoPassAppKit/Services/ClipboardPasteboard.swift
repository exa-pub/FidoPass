import AppKit

@MainActor
protocol ClipboardPasteboard {
    var changeCount: Int { get }
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
    func clearContents() -> Int
}

extension NSPasteboard: ClipboardPasteboard {}
