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

    /// The manager's change-PIN sheet and the panel's bootstrap screen used to edit the same
    /// fields. Closing the panel — which happens the moment any other window takes focus —
    /// wiped a PIN the user was halfway through typing in the manager.
    func testClosingThePanelLeavesTheManagerPinFormAlone() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        let manager = HUDTestFactory.manager(for: store)
        manager.pinForm.current = "1234"
        manager.pinForm.new = "246813"
        manager.pinForm.confirm = "246813"

        store.panelDidClose()

        XCTAssertEqual(manager.pinForm.current, "1234",
                       "closing the panel must not touch a form that belongs to another window")
        XCTAssertEqual(manager.pinForm.new, "246813")
    }

    /// And the other way round: the panel's own bootstrap form is the one `panelDidClose` wipes.
    func testClosingThePanelClearsItsOwnForm() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        store.pinForm.new = "246813"

        store.panelDidClose()

        XCTAssertTrue(store.pinForm.isEmpty)
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
