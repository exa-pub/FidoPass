import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Owns the menu-bar item and the panel, and decides when the panel may close.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private let store: PanelStore
    private let devices: DeviceStore
    private let generation: GenerationStore
    private let touchGate: TouchGate
    private var statusItem: NSStatusItem?
    private var panel: PanelWindow?
    private var hosting: NSHostingController<PanelRootView>?
    // Removed in `deinit`, which is not isolated; never touched anywhere else.
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    private var iconSubscription: AnyCancellable?

    init(container: AppContainer) {
        self.store = container.panel
        self.devices = container.devices
        self.generation = container.generation
        self.touchGate = container.touchGate
        super.init()

        // The icon is a function of store state, so it follows the stores instead of being
        // told. `objectWillChange` fires before the change lands, hence the hop to the next
        // run-loop turn before the state is read.
        iconSubscription = Publishers.Merge4(store.objectWillChange,
                                             devices.objectWillChange,
                                             generation.objectWillChange,
                                             touchGate.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
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
        menu.addItem(withTitle: "Encrypt a message…", action: #selector(menuEncryptMessage), keyEquivalent: "").target = self
        let decrypt = NSMenuItem(title: "Decrypt a message…", action: #selector(menuDecryptMessage), keyEquivalent: "")
        decrypt.target = self
        // Opening messages needs the selected key unlocked; a disabled item says so better
        // than a PIN prompt would.
        decrypt.isEnabled = store.isSelectedKeyUnlocked
        menu.addItem(decrypt)
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
    @objc private func menuLock() { store.lockSelectedKey() }
    @objc private func menuPreferences() { store.openPreferences() }
    @objc private func menuQuit() { store.quit() }

    @objc private func menuCopyPassword() {
        guard let ref = store.selection else { show(); return }
        show(intent: .copyPassword(ref, label: store.labelEditor.current))
    }

    /// Needs no key: the sending window works from a link alone.
    @objc private func menuEncryptMessage() { store.openEncryptor() }

    /// Only offered while the selected key is unlocked — see `showStatusMenu`.
    @objc private func menuDecryptMessage() { store.openDecryptor() }

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

    func show(intent: PanelIntent? = nil) {
        let panel = ensurePanel()
        position(panel)
        // An accessory app has no windows of its own to activate, so without this the panel
        // appears behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // The first placement uses the panel's placeholder height, because SwiftUI has not
        // laid the content out yet. Place it again once it has.
        DispatchQueue.main.async { [weak self] in self?.position(panel) }
        Task { await store.prepareForDisplay(intent: intent) }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        store.panelDidClose()
    }

    private func ensurePanel() -> PanelWindow {
        if let panel { return panel }
        let controller = NSHostingController(rootView: PanelRootView(store: store))
        controller.sizingOptions = [.preferredContentSize]
        let panel = PanelWindow(contentViewController: controller)
        panel.delegate = self
        panel.onCancel = { [weak self] in
            guard let self else { return }
            // On a pushed screen Escape means "back"; only on the top level does it close
            // the panel.
            if !self.store.handleEscape() { self.hide() }
        }
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
        touchGate.panelPrompt != nil || store.isPinnedOpen || touchGate.isPanelBusy
    }

    private func position(_ panel: PanelWindow) {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else {
            // No status item geometry yet. Anywhere near the menu bar beats the middle of
            // the screen, which is where an unplaced window lands.
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 12,
                                             y: visible.maxY - panel.frame.height - 6))
            }
            return
        }

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
    func presentSavePanel(for sheet: RecoverySheet) {
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
                    self.store.recoverySheetFinished(saved: false, failure: error.localizedDescription)
                }
            }
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
