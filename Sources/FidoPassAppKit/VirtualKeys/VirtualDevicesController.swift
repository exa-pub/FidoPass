import AppKit
import SwiftUI

@MainActor
final class VirtualDevicesController: NSObject {
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
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.worksWhenModal = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.setFrameAutosaveName("VirtualDevices")
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
