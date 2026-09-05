import XCTest
import FidoPassCore
@testable import FidoPassAppKit

@MainActor
final class LabelEditorTests: AppTestCase {
    private func editor(recent: [String] = ["work"]) -> LabelEditor {
        let history = LabelStore(userDefaults: AppTestFactory.makeDefaults())
        let target = LabelTarget(scope: LabelScope(credentialId: "cred"), accountId: "vault",
                                 deviceSignature: "1050:0407", deviceName: "Key")
        for label in recent.reversed() { history.use(label, in: target) }
        let editor = LabelEditor(history: history)
        editor.focus(target)
        return editor
    }

    func testOneVisibleValueStartsFromHistoryOrDefault() {
        let recent = editor()
        XCTAssertEqual(recent.current, "work")
        XCTAssertEqual(recent.draft, recent.current)
        let empty = editor(recent: [])
        XCTAssertEqual(empty.current, "default")
        XCTAssertEqual(empty.draft, "default")
    }

    func testHistorySelectionReplacesDraftAndEscapeRestoresIt() {
        let editor = editor()
        editor.setEditing(true)
        editor.draftChanged("new")
        editor.set("work")
        editor.setEditing(true)
        XCTAssertEqual(editor.draft, "work")
        editor.draftChanged("other")
        XCTAssertTrue(editor.escape())
        XCTAssertEqual(editor.current, "work")
        XCTAssertEqual(editor.draft, "work")
        XCTAssertFalse(editor.escape())
    }

    func testEmptyDraftNeverUsesPreviousLabelEvenAfterLosingFocus() {
        let editor = editor()
        editor.setEditing(true)
        editor.draftChanged("")
        editor.setEditing(false)
        XCTAssertEqual(editor.current, "")
        XCTAssertFalse(editor.canGenerate)
        XCTAssertTrue(editor.escape(), "Escape also restores an unfinished draft after focus moves")
        XCTAssertEqual(editor.current, "work")
    }

    func testWhitespaceRequiresExplicitCompatibilityChoice() {
        let editor = editor()
        editor.draftChanged("  vault  ")
        XCTAssertFalse(editor.canGenerate)
        XCTAssertEqual(editor.current, "  vault  ")
        editor.useTrimmedLabel()
        XCTAssertEqual(editor.current, "vault", "the explicit choice preserves the earlier UI contract")
        XCTAssertTrue(editor.canGenerate)
        editor.draftChanged("  vault  ")
        editor.keepExactLabel()
        XCTAssertTrue(editor.canGenerate)
        XCTAssertTrue(editor.current.utf8.elementsEqual("  vault  ".utf8))
        editor.draftChanged("  vault   ")
        XCTAssertFalse(editor.canGenerate, "editing requires a new choice")
    }

    func testNBSPControlsAndWhitespaceOnlyHaveExplicitOutcomes() {
        let editor = editor()
        for label in ["\u{00A0}vault", "vault\u{00A0}backup", "   "] {
            editor.draftChanged(label)
            XCTAssertFalse(editor.canGenerate)
            editor.keepExactLabel()
            XCTAssertTrue(editor.canGenerate)
            XCTAssertTrue(editor.current.utf8.elementsEqual(label.utf8))
        }
        for label in ["vault\t", "vault\n", "va\u{200B}ult"] {
            editor.draftChanged(label)
            editor.keepExactLabel()
            XCTAssertFalse(editor.canGenerate)
        }
        editor.draftChanged("   ")
        editor.useTrimmedLabel()
        XCTAssertFalse(editor.canGenerate)
    }

    func testHistoryBytesAreTrustedWithoutNewNormalization() {
        for label in [" vault ", "vault\t", "caf\u{00E9}", "cafe\u{0301}", "Vault"] {
            let editor = editor(recent: [label])
            XCTAssertTrue(editor.canGenerate)
            XCTAssertTrue(editor.current.utf8.elementsEqual(label.utf8))
        }
    }

    func testFocusingAnotherAccountDropsTheDraft() {
        let editor = editor()
        editor.setEditing(true)
        editor.draftChanged("custom")
        editor.focus(nil)
        XCTAssertEqual(editor.current, "default")
        XCTAssertEqual(editor.draft, "default")
        XCTAssertFalse(editor.isEditing)
    }
}
