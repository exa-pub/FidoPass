import AppKit
import XCTest
@testable import FidoPassAppKit

@MainActor
final class AppMenuTests: AppTestCase {
    func testCommandWClosesOnlyTheKeyPanelThroughItsDelegate() async throws {
        try await withMainMenu {
            let other = makePanel()
            defer { other.close() }
            other.makeKeyAndOrderFront(nil)
            let window = makePanel()
            let probe = CloseProbe()
            window.delegate = probe
            defer { window.close() }
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
            window.contentView?.addSubview(field)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            try await waitUntil { NSApp.keyWindow === window }

            try commandW(in: window)
            try await waitUntil { !window.isVisible }
            XCTAssertEqual(probe.closedCount, 1)
            XCTAssertTrue(other.isVisible, "Close must not affect a different window")
        }
    }

    func testCommandWHonorsTheWindowsCloseVeto() async throws {
        try await withMainMenu {
            let window = makePanel()
            defer { window.close() }
            let probe = CloseProbe()
            probe.allowsClose = false
            window.delegate = probe
            window.makeKeyAndOrderFront(nil)
            try await waitUntil { NSApp.keyWindow === window }

            try commandW(in: window)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(probe.closedCount, 0)

            probe.allowsClose = true
            try commandW(in: window)
            try await waitUntil { !window.isVisible }
            XCTAssertEqual(probe.closedCount, 1)
        }
    }

    func testHUDCloseIsDifferentFromEscapeNavigation() async throws {
        try await withMainMenu {
            let panel = PanelWindow(contentViewController: NSViewController())
            defer { panel.close() }
            var closed = 0
            var wentBack = 0
            panel.onClose = { closed += 1; panel.orderOut(nil) }
            panel.onCancel = { wentBack += 1 }
            panel.makeKeyAndOrderFront(nil)
            try await waitUntil { NSApp.keyWindow === panel }

            try commandW(in: panel)
            XCTAssertEqual(closed, 1)
            XCTAssertEqual(wentBack, 0)
            XCTAssertFalse(panel.isVisible)

            panel.makeKeyAndOrderFront(nil)
            panel.cancelOperation(nil)
            XCTAssertEqual(closed, 1)
            XCTAssertEqual(wentBack, 1)
        }
    }

    private func withMainMenu(_ body: () async throws -> Void) async rethrows {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        let delegate = AppDelegate()
        delegate.installMainMenu()
        try await body()
    }

    private func commandW(in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13))
        NSApp.sendEvent(event)
    }

    // Nonactivating panels can become key in the command-line test host.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        return panel
    }
}

@MainActor
private final class CloseProbe: NSObject, NSWindowDelegate {
    var allowsClose = true
    var closedCount = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool { allowsClose }
    func windowWillClose(_ notification: Notification) { closedCount += 1 }
}
