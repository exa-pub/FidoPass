import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// What one window may and may not do to another.
///
/// The panel and the manager are separate windows, and the state each one edits must belong to
/// it alone. These tests pin that boundary before the stores behind the two windows are split.
@MainActor
final class WindowIsolationTests: XCTestCase {

    /// The manager's change-PIN sheet and the panel's bootstrap screen edit the same fields
    /// today. Closing the panel — which happens the moment any other window takes focus —
    /// wipes a PIN the user is halfway through typing in the manager.
    ///
    /// Pinned as an expected failure: the fix is structural (one form per window) and lands
    /// with the store split. Until then this test documents the defect rather than hiding it.
    func testClosingThePanelLeavesTheManagerPinFormAlone() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        store.pinForm.current = "1234"
        store.pinForm.new = "246813"
        store.pinForm.confirm = "246813"

        store.panelDidClose()

        XCTExpectFailure("the change-PIN form is shared with the panel until the store split") {
            XCTAssertEqual(store.pinForm.current, "1234",
                           "closing the panel must not touch a form that belongs to another window")
            XCTAssertEqual(store.pinForm.new, "246813")
        }
    }

    // MARK: - Menu-bar icon

    /// The icon is the one thing visible while the panel is closed, so its state is derived
    /// from the stores rather than remembered separately.
    func testIconReflectsLockingTheKey() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        XCTAssertEqual(store.iconState, .unlocked)

        store.lockSelectedKey()

        XCTAssertEqual(store.iconState, .locked)
    }

    func testIconReflectsAnUnpluggedKey() async {
        let (store, backend, _) = await HUDTestFactory.unlockedStore()
        backend.devices = []

        await store.refresh()

        XCTAssertEqual(store.iconState, .noKey)
    }

    /// Abandoning a touch hides the prompt at once, whatever the key is still doing.
    func testAbandoningATouchReturnsTheIconToItsRestingState() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        let latch = Latch()

        let operation = Task { @MainActor in
            await store.withTouchPrompt(TouchPrompt(title: "Touch", message: "Now", deviceName: "Key")) {
                await withCheckedContinuation { latch.continuation = $0 }
            }
        }
        for _ in 0..<50 where store.touch == nil { await Task.yield() }
        XCTAssertEqual(store.iconState, .waitingForTouch)

        store.abandonTouch()

        XCTAssertEqual(store.iconState, .unlocked)
        latch.continuation?.resume()
        await operation.value
    }

    private final class Latch: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
    }
}
