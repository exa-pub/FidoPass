import SwiftUI
import AppKit

/// TextKit editor with optional glyph masking. Disables substitutions to preserve bytes
/// and disables spelling, grammar and detection services to avoid exporting plaintext.
struct PlainTextEditor: NSViewRepresentable {
    @Environment(\.clipboard) private var clipboard
    @Binding var text: String
    var isEditable: Bool = true
    var monospaced: Bool = false
    var isMasked: Bool = false
    var isSingleLine: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = MaskingLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.maximumNumberOfLines = isSingleLine ? 1 : 0
        container.lineBreakMode = isSingleLine ? .byTruncatingMiddle : .byWordWrapping
        layoutManager.addTextContainer(container)

        let textView = SecretTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = !isSingleLine
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = isSingleLine ? [.width, .height] : [.width]

        textView.clipboard = clipboard
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.font = font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        layoutManager.isMasked = isMasked

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = !isSingleLine
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if let layoutManager = textView.layoutManager as? MaskingLayoutManager, layoutManager.isMasked != isMasked {
            layoutManager.isMasked = isMasked
            textView.needsDisplay = true
        }
        (textView as? SecretTextView)?.clipboard = clipboard
        if text.isEmpty { textView.clearIncludingUndoHistory(); return }
        guard !textView.string.utf8.elementsEqual(text.utf8) else { return }

        // Preserve the caret across programmatic updates, otherwise typing on one side
        // sends the cursor to the start of the other every time it is recomputed.
        let selected = textView.selectedRange()
        textView.string = text
        let bounded = NSRange(location: min(selected.location, text.utf16.count), length: 0)
        textView.setSelectedRange(bounded)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        guard let text = view.documentView as? NSTextView else { return }
        text.clearIncludingUndoHistory()
        text.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Masks glyphs during layout so caret and selection match the visible bullets.
/// Whitespace and line breaks retain their glyphs.
final class MaskingLayoutManager: NSLayoutManager {
    var isMasked = false {
        didSet {
            guard isMasked != oldValue, let storage = textStorage else { return }
            let everything = NSRange(location: 0, length: storage.length)
            invalidateGlyphs(forCharacterRange: everything, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: everything, actualCharacterRange: nil)
        }
    }

    override func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>,
                            properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                            characterIndexes: UnsafePointer<Int>,
                            font: NSFont,
                            forGlyphRange glyphRange: NSRange) {
        guard isMasked, let storage = textStorage, let bullet = Self.bulletGlyph(in: font) else {
            super.setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            return
        }
        let string = storage.string as NSString
        var masked = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        for index in 0..<glyphRange.length {
            // Control glyphs (line breaks, tabs) and whitespace keep their own glyph.
            guard properties[index] == [] else { continue }
            let characterIndex = characterIndexes[index]
            guard characterIndex < string.length else { continue }
            switch string.character(at: characterIndex) {
            case 0x20, 0x09, 0x0A, 0x0D, 0x2028, 0x2029, 0xA0:
                continue
            default:
                masked[index] = bullet
            }
        }
        masked.withUnsafeBufferPointer { buffer in
            super.setGlyphs(buffer.baseAddress!, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        }
    }

    /// The bullet in this font, or nil when the font has none — then the text is drawn as
    /// it is rather than as nothing.
    private static func bulletGlyph(in font: NSFont) -> CGGlyph? {
        var characters: [UniChar] = [0x2022]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }
}

extension NSTextView {
    /// Clears the text and the undo history together.
    ///
    /// Emptying the text alone leaves the plaintext recoverable through Undo for as long as
    /// the view lives.
    func clearIncludingUndoHistory() {
        string = ""
        undoManager?.removeAllActions()
    }
}
