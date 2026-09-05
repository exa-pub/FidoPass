import Foundation

/// One visible label, with an explicit rollback point and byte-preserving history.
@MainActor
final class LabelEditor: ObservableObject {
    @Published private(set) var current = LabelStore.fallback
    @Published private(set) var draft = LabelStore.fallback
    @Published private(set) var isEditing = false
    @Published private(set) var caretAtEnd = false
    @Published private(set) var acceptsExactWhitespace = true

    private var committed = LabelStore.fallback
    private let history: LabelStore

    init(history: LabelStore) { self.history = history }

    var chips: [String] { history.chips }

    var needsWhitespaceChoice: Bool {
        !acceptsExactWhitespace && (draft != draft.trimmingCharacters(in: .whitespacesAndNewlines)
            || draft.unicodeScalars.contains { CharacterSet.whitespaces.contains($0) && $0 != " " })
    }

    var issue: String? {
        guard !current.isEmpty else { return "Enter a label, or choose default." }
        // Existing history is used exactly as stored, including older unusual labels.
        guard !acceptsExactWhitespace else { return nil }
        if current.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
        }) {
            return "Remove tabs, line breaks and invisible control characters from this new label."
        }
        if needsWhitespaceChoice { return "Choose how to use the whitespace in this label." }
        return nil
    }

    var canGenerate: Bool { issue == nil }

    func focus(_ target: LabelTarget?) {
        history.focus(target)
        set(PanelReducer.resolveLabel(recent: history.recent))
    }

    func set(_ label: String) {
        committed = label
        draft = label
        acceptsExactWhitespace = true
        current = label
        isEditing = false
    }

    func adopt(_ label: String) { set(label) }

    func draftChanged(_ text: String) {
        draft = text
        acceptsExactWhitespace = false
        current = text
    }

    func useTrimmedLabel() {
        draftChanged(draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func keepExactLabel() {
        guard needsWhitespaceChoice,
              !draft.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
              }) else { return }
        acceptsExactWhitespace = true
    }

    func setEditing(_ editing: Bool) { isEditing = editing }

    /// Arrow navigation walks history, then the editor; selecting history replaces the draft.
    func moveFocus(by offset: Int) {
        let fieldIndex = chips.count
        let position = isEditing ? fieldIndex
            : (chips.firstIndex { $0.utf8.elementsEqual(current.utf8) } ?? fieldIndex)
        let next = (position + offset + fieldIndex + 1) % (fieldIndex + 1)
        if next == fieldIndex {
            caretAtEnd = offset < 0
            setEditing(true)
        } else {
            set(chips[next])
        }
    }

    func escape() -> Bool {
        guard isEditing || !draft.utf8.elementsEqual(committed.utf8) else { return false }
        set(committed)
        return true
    }
}
