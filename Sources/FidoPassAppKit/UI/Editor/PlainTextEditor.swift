import SwiftUI
import AppKit

/// A text view with every macOS text convenience switched off.
///
/// SwiftUI's `TextEditor` inherits the system defaults, and each of them is actively
/// harmful here:
///
/// - smart quotes and dash substitution silently rewrite characters, which corrupts base64
///   and changes the plaintext being encrypted;
/// - spelling, grammar and autocorrect hand the text to system services and keep it in
///   their own buffers — for a secret, that is an unwanted copy outside this process;
/// - data and link detection make the system parse the content looking for addresses,
///   phone numbers and URLs.
///
/// None of these can be turned off through the SwiftUI API, so the text view is wrapped
/// directly.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var monospaced: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

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

        textView.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 8)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        guard textView.string != text else { return }

        // Preserve the caret across programmatic updates, otherwise typing on one side
        // sends the cursor to the start of the other every time it is recomputed.
        let selected = textView.selectedRange()
        textView.string = text
        let bounded = NSRange(location: min(selected.location, text.utf16.count), length: 0)
        textView.setSelectedRange(bounded)
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
