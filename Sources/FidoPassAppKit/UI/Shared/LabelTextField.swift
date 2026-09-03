import AppKit
import SwiftUI

/// The custom-label field, as an `NSTextField`.
///
/// SwiftUI's `TextField` does not expose the caret, and the caret is exactly what decides
/// here: a left arrow means "move the cursor" everywhere except at the very start of the
/// text, where it means "leave the field and go back to the chips". Guessing that from
/// keystrokes alone is not possible, so the field is the AppKit one.
struct LabelTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    /// Put the caret at the end rather than the start when focus arrives programmatically.
    var caretAtEnd: Bool
    var onSubmit: () -> Void
    /// Left arrow pressed with the caret at the start and nothing selected.
    var onExitLeft: () -> Void
    /// Right arrow pressed with the caret at the end and nothing selected.
    var onExitRight: () -> Void
    /// Up and down never move a caret in a single-line field, so they keep meaning
    /// "previous / next account" even while a label is being typed.
    var onMoveAccount: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        // While a field editor is live it owns the text. Assigning `stringValue` underneath
        // it resets the selection and takes the caret with it.
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }

        let isEditing = nsView.currentEditor() != nil
        guard isFocused != isEditing else { return }
        if isFocused {
            context.coordinator.focus(nsView, caretAtEnd: caretAtEnd)
        } else {
            context.coordinator.blur(nsView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LabelTextField
        private var isChangingResponder = false

        init(_ parent: LabelTextField) {
            self.parent = parent
        }

        /// Takes focus and leaves a caret rather than a selection.
        ///
        /// `makeFirstResponder` on a text field selects its whole contents — which on a field
        /// that already holds a draft looks like anything but a place to type. The selection
        /// is collapsed straight after, and again on the next pass if the field editor is not
        /// installed yet.
        func focus(_ field: NSTextField, caretAtEnd: Bool) {
            guard !isChangingResponder else { return }
            isChangingResponder = true
            // Deferred: a responder change inside a SwiftUI update re-enters layout.
            DispatchQueue.main.async { [weak self, weak field] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let field, let window = field.window else {
                        self.isChangingResponder = false
                        return
                    }
                    window.makeFirstResponder(field)
                    self.placeCaret(in: field, atEnd: caretAtEnd, attempt: 0)
                }
            }
        }

        func blur(_ field: NSTextField) {
            guard !isChangingResponder else { return }
            isChangingResponder = true
            DispatchQueue.main.async { [weak self, weak field] in
                MainActor.assumeIsolated {
                    if let field, field.currentEditor() != nil {
                        field.window?.makeFirstResponder(nil)
                    }
                    self?.isChangingResponder = false
                }
            }
        }

        private func placeCaret(in field: NSTextField, atEnd: Bool, attempt: Int) {
            guard let editor = field.currentEditor() else {
                guard attempt < 3 else {
                    isChangingResponder = false
                    return
                }
                DispatchQueue.main.async { [weak self, weak field] in
                    MainActor.assumeIsolated {
                        guard let self, let field else { return }
                        self.placeCaret(in: field, atEnd: atEnd, attempt: attempt + 1)
                    }
                }
                return
            }
            let length = (field.stringValue as NSString).length
            editor.selectedRange = NSRange(location: atEnd ? length : 0, length: 0)
            isChangingResponder = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveLeft(_:)):
                let range = textView.selectedRange()
                // Anywhere but the start, the arrow belongs to the caret.
                guard range.location == 0, range.length == 0 else { return false }
                parent.onExitLeft()
                return true
            case #selector(NSResponder.moveRight(_:)):
                let range = textView.selectedRange()
                // Same rule at the other end: the caret first, the row only once it has
                // nowhere left to go. An empty field is at both ends at once, so either
                // arrow leaves it.
                let end = (textView.string as NSString).length
                guard range.location + range.length == end, range.length == 0 else { return false }
                parent.onExitRight()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveAccount(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveAccount(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.isFocused = false
                return true
            default:
                return false
            }
        }
    }
}
