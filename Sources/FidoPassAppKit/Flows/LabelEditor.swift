import Foundation

/// Label selection and editing. The draft survives focus changes and chip selection
/// to avoid losing an input needed to reproduce a password.
@MainActor
final class LabelEditor: ObservableObject {

    /// The label the next password derives from.
    @Published private(set) var current: String = LabelStore.fallback
    /// Text in the custom field.
    @Published private(set) var draft: String = ""
    /// True while the label is being typed rather than picked. Arrow keys belong to the text
    /// field then, not to the list behind it.
    @Published private(set) var isEditing = false
    /// Where the caret goes when the arrows move focus into the custom field: at the end when
    /// arriving from the right, so the next press keeps moving in the same direction instead
    /// of bouncing straight back out.
    @Published private(set) var caretAtEnd = false

    private let history: LabelStore

    init(history: LabelStore) {
        self.history = history
    }

    /// The chips on the row. The keyboard walks exactly this list, so it and the view can
    /// never disagree about what comes next.
    var chips: [String] { history.chips }

    /// Points the row at an account's history and starts from the label used with it last.
    ///
    /// The draft belongs to the account it was typed for, so it does not travel with the row.
    func focus(_ target: LabelTarget?) {
        history.focus(target)
        current = PanelReducer.resolveLabel(recent: history.recent)
        draft = chips.contains(where: { $0.utf8.elementsEqual(current.utf8) }) ? "" : current
    }

    /// A chip was picked, or a screen set the label outright.
    func set(_ label: String) {
        isEditing = false
        current = label
        if !chips.contains(where: { $0.utf8.elementsEqual(label.utf8) }) { draft = label }
    }

    /// A password was just derived with `label`, so it is the label now — whatever the row
    /// was showing while the key was being touched.
    func adopt(_ label: String) {
        current = label
    }

    /// Typing in the field: the text is the label the moment it is non-empty.
    func draftChanged(_ text: String) {
        draft = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        current = trimmed
    }

    /// Focus moved into or out of the field.
    func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if editing {
            // Stepping back into the field means going back to what was typed there.
            if !typed.isEmpty { current = typed }
        } else if !chips.contains(where: { $0.utf8.elementsEqual(current.utf8) }) {
            draft = current
        }
    }

    /// Walks the row: chip, chip, …, and then the custom field.
    ///
    /// The field is a position like any other, so the arrows reach it instead of stopping at
    /// the last chip. It is the last one, and once inside, the caret decides — the field
    /// itself only hands control back when the caret is already at the start.
    func moveFocus(by offset: Int) {
        let chips = self.chips
        let fieldIndex = chips.count          // the custom field is the last position
        let count = fieldIndex + 1
        guard count > 1 else { return }

        // Standing on the field means either typing in it, or having a label that is not one
        // of the chips — that text lives there whether or not it has focus.
        let position = isEditing || !chips.contains(where: { $0.utf8.elementsEqual(current.utf8) })
            ? fieldIndex
            : (chips.firstIndex(where: { $0.utf8.elementsEqual(current.utf8) }) ?? 0)

        // Wraps: with three or four positions, a dead end at each edge is just a key that
        // does nothing.
        let next = (position + offset + count) % count
        guard next != position || offset == 0 else { return }

        if next == fieldIndex {
            caretAtEnd = offset < 0
            setEditing(true)
        } else {
            set(chips[next])
        }
    }

    /// Escape while typing leaves the field. Returns false when there was nothing to leave.
    func escape() -> Bool {
        guard isEditing else { return false }
        setEditing(false)
        return true
    }
}
