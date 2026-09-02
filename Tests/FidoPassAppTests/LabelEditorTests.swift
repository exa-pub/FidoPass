import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// The label row on its own: what the field holds, and how a draft survives.
@MainActor
final class LabelEditorTests: XCTestCase {

    private func editor(recent: [String]) -> LabelEditor {
        let suite = "LabelEditorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let history = LabelStore(userDefaults: defaults,
                                 ubiStore: InMemoryUbiquitousStore(),
                                 notificationCenter: NotificationCenter())
        let target = LabelTarget(scope: LabelScope(credentialId: "cred"), accountId: "vault",
                                 deviceSignature: "1050:0407", deviceName: "Key")
        for label in recent.reversed() { history.use(label, in: target) }
        let editor = LabelEditor(history: history)
        editor.focus(target)
        return editor
    }

    func testStartsFromTheLabelUsedLast() {
        let editor = editor(recent: ["work", "archive"])
        XCTAssertEqual(editor.current, "work")
        XCTAssertEqual(editor.draft, "", "a chip shows it; the field stays empty")
    }

    func testAnAccountWithNoHistoryStartsFromTheDefault() {
        let editor = editor(recent: [])
        XCTAssertEqual(editor.current, LabelStore.fallback)
    }

    /// Text typed into the field is a draft: it survives picking a chip, because retyping a
    /// label is exactly the mistake that derives a different password.
    func testADraftSurvivesPickingAChip() {
        let editor = editor(recent: ["work"])
        editor.setEditing(true)
        editor.draftChanged("something-new")
        XCTAssertEqual(editor.current, "something-new")

        editor.set("work")
        XCTAssertEqual(editor.current, "work")
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(editor.draft, "something-new", "the text is still there for the next visit")

        editor.setEditing(true)
        XCTAssertEqual(editor.current, "something-new", "stepping back into the field goes back to what was typed")
    }

    /// Whitespace around a label would derive a different password from the one the user
    /// meant, and an empty field is not a label at all.
    func testTypingTrimsAndIgnoresEmptiness() {
        let editor = editor(recent: ["work"])
        editor.setEditing(true)
        editor.draftChanged("  vault  ")
        XCTAssertEqual(editor.current, "vault")

        editor.draftChanged("   ")
        XCTAssertEqual(editor.current, "vault", "clearing the field does not make the label empty")
    }

    /// Switching account switches history, and the draft belongs to the account it was
    /// typed for.
    func testFocusingAnotherAccountDropsTheDraft() {
        let editor = editor(recent: ["work"])
        editor.setEditing(true)
        editor.draftChanged("custom")
        editor.setEditing(false)

        editor.focus(nil)

        XCTAssertEqual(editor.current, LabelStore.fallback)
        XCTAssertEqual(editor.draft, "")
    }

    func testEscapeLeavesTheFieldAndReportsIt() {
        let editor = editor(recent: ["work"])
        XCTAssertFalse(editor.escape(), "nothing to leave")
        editor.setEditing(true)
        XCTAssertTrue(editor.escape())
        XCTAssertFalse(editor.isEditing)
    }
}
