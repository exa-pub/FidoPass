import AppKit
import SwiftUI

@MainActor
final class VirtualDevicesController: NSObject, NSWindowDelegate {
    private let store: VirtualDeviceStore
    private(set) var window: NSPanel?

    init(store: VirtualDeviceStore) { self.store = store }

    func show() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 610, height: 400),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "Virtual Devices"
            panel.contentViewController = NSHostingController(rootView: VirtualDevicesView(store: store))
            panel.setContentSize(NSSize(width: 610, height: 400))
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.worksWhenModal = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let restored = panel.setFrameUsingName("VirtualDevices")
            panel.setFrameAutosaveName("VirtualDevices")
            panel.delegate = self
            let visible = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
            if let welcome = NSApp.windows.first(where: { $0.isVisible && $0.title == "Welcome to FidoPass" }) {
                panel.setFrame(WindowPlacement.beside(welcome.frame, size: panel.frame.size, in: visible), display: false)
            } else if !restored {
                panel.setFrameOrigin(NSPoint(x: visible.minX + 16, y: visible.minY + 16))
            }
            window = panel
        }
        keepOnScreen()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    private func keepOnScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let frame = WindowPlacement.clamped(window.frame, to: screen.visibleFrame)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    func windowDidChangeScreen(_ notification: Notification) { keepOnScreen() }
    func windowDidResize(_ notification: Notification) { keepOnScreen() }
}
