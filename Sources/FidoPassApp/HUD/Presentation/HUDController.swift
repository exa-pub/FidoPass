#if canImport(AppKit)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the menu-bar item and the panel, and decides when the panel may close.
@MainActor
final class HUDController: NSObject, NSWindowDelegate {

    private let store: HUDStore
    private var statusItem: NSStatusItem?
    private var panel: HUDPanel?
    private var hosting: NSHostingController<HUDRootView>?
    private var resignObserver: NSObjectProtocol?

    init(store: HUDStore) {
        self.store = store
        super.init()

        store.onRequestClose = { [weak self] in self?.hide() }
        store.onStateChanged = { [weak self] in self?.updateIcon() }
        store.onRequestOpenEditor = { [weak store] session in
            AuxiliaryWindows.shared.showEditor(session: session) {
                Task { @MainActor in store?.editorWindowClosed() }
            }
        }
        store.onRequestCloseEditor = { AuxiliaryWindows.shared.closeEditor() }
        store.onRequestSaveRecoverySheet = { [weak self] sheet in self?.presentSavePanel(for: sheet) }
    }

    // MARK: - Status item

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = [.removalAllowed]
        item.autosaveName = "FidoPassStatusItem"
        if let button = item.button {
            button.image = StatusItemIcon.image(for: .noKey)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "FidoPass"
        }
        statusItem = item
        updateIcon()
    }

    @objc private func statusItemClicked() {
        // Right-click is a second, fully keyboard-free path to every action — the plan's
        // answer to "context menus are invisible".
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            toggle()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open FidoPass", action: #selector(menuOpen), keyEquivalent: "").target = self
        let copy = NSMenuItem(title: copyItemTitle, action: #selector(menuCopyPassword), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = store.selection != nil
        menu.addItem(copy)
        menu.addItem(.separator())
        menu.addItem(withTitle: "New account…", action: #selector(menuNewAccount), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Encrypt text…", action: #selector(menuEncrypt), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save recovery sheet…", action: #selector(menuRecoverySheet), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Backup key…", action: #selector(menuBackupKey), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Lock key", action: #selector(menuLock), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Preferences…", action: #selector(menuPreferences), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit FidoPass", action: #selector(menuQuit), keyEquivalent: "q").target = self

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private var copyItemTitle: String {
        guard let selection = store.selection else { return "Copy password" }
        return "Copy password for \(selection.accountId)"
    }

    @objc private func menuOpen() { show() }
    @objc private func menuNewAccount() { show(intent: .enroll) }
    @objc private func menuLock() { store.lockSelectedKey(); updateIcon() }
    @objc private func menuPreferences() { AuxiliaryWindows.shared.showPreferences(store: store) }
    @objc private func menuQuit() { NSApplication.shared.terminate(nil) }

    @objc private func menuCopyPassword() {
        guard let ref = store.selection else { show(); return }
        show(intent: .copyPassword(ref, label: store.labels.current))
    }

    @objc private func menuEncrypt() {
        guard let ref = store.selection else { show(); return }
        show()
        Task { await store.openEncryptEditor(for: ref) }
    }

    @objc private func menuRecoverySheet() {
        guard let ref = store.selection else { show(); return }
        show()
        store.saveRecoverySheet(for: ref)
    }

    @objc private func menuBackupKey() {
        guard let ref = store.selection else { show(); return }
        show()
        Task { await store.showBackupKey(for: ref) }
    }

    func updateIcon() {
        let state = store.iconState
        guard let button = statusItem?.button else { return }
        button.image = StatusItemIcon.image(for: state)
        button.toolTip = StatusItemIcon.description(for: state)
        // "Unlocked" and "a secret is on the clipboard" draw the same key symbol, so the
        // second state gets a dot: it is one of the two things the user would otherwise have
        // to open the HUD to check.
        button.title = StatusItemIcon.badgeVisible(for: state) ? " •" : ""
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
    }

    // MARK: - Panel

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show(intent: HUDIntent? = nil) {
        let panel = ensurePanel()
        position(panel)
        // An accessory app has no windows of its own to activate, so without this the panel
        // appears behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Task { await store.prepareForDisplay(intent: intent) }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        store.panelDidClose()
        updateIcon()
    }

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }
        let controller = NSHostingController(rootView: HUDRootView(store: store))
        controller.sizingOptions = [.preferredContentSize]
        let panel = HUDPanel(contentViewController: controller)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        self.hosting = controller
        self.panel = panel

        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: panel,
                                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleResignKey() }
        }
        return panel
    }

    /// Clicking away closes the HUD — unless it is in the middle of something the user
    /// cannot get back with one click.
    private func handleResignKey() {
        guard !isSticky else { return }
        hide()
    }

    private var isSticky: Bool {
        store.touch != nil || store.isPinnedOpen || store.isWorking
    }

    private func position(_ panel: HUDPanel) {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(x: buttonRect.midX - size.width / 2,
                             y: buttonRect.minY - size.height - 6)

        // Keep it on screen when the icon sits near a corner.
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrameOrigin(origin)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        position(panel)
    }

    // MARK: - Recovery sheet

    /// Runs as a sheet on the HUD panel.
    ///
    /// A modal save panel from an accessory app would drop the HUD behind it and, because
    /// the panel loses key, close it outright — losing the screen the user started from.
    private func presentSavePanel(for sheet: RecoverySheet) {
        guard let panel else { return }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = sheet.suggestedFileName
        savePanel.allowedContentTypes = [.plainText]
        savePanel.message = "This sheet contains no passwords, PIN or backup key."
        savePanel.beginSheetModal(for: panel) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                guard response == .OK, let url = savePanel.url else {
                    self.store.recoverySheetFinished(saved: false)
                    return
                }
                do {
                    try sheet.render().write(to: url, atomically: true, encoding: .utf8)
                    self.store.recoverySheetFinished(saved: true)
                } catch {
                    self.store.errorText = "Could not save the recovery sheet: \(error.localizedDescription)"
                    self.store.recoverySheetFinished(saved: false)
                }
            }
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
#endif
