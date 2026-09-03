import AppKit
import SwiftUI

/// The window the HUD lives in.
///
/// A plain `NSPopover` (or SwiftUI's `MenuBarExtra`) cannot be opened from a global hotkey
/// and closes itself the moment a save panel appears or the key is being touched. Owning the
/// window is what buys those two things; `canBecomeKey` is what lets the PIN field work at
/// all, since a non-activating panel refuses first responder by default.
final class PanelWindow: NSPanel {

    init(contentViewController: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 200),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered,
                   defer: false)
        self.contentViewController = contentViewController
        isFloatingPanel = true
        level = .statusBar
        // Closing is decided by the controller: during a touch, an enrolment or a system
        // panel the HUD must stay put.
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        // Tab between fields is *not* solved here. A borderless window builds no key-view
        // loop, and `autorecalculatesKeyViewLoop` was tried and changed nothing — the field
        // editor still had no `nextKeyView`. Each multi-field screen states its own order
        // with `tabFocusChain` instead.
    }

    /// Called when the user presses Escape. `performClose` would only beep — a borderless
    /// window has no close button for it to find.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes the panel, the way every other menu-bar window behaves.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
