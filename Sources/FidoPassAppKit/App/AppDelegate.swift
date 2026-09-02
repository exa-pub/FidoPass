import AppKit

/// The application, assembled.
///
/// Plain AppKit rather than a SwiftUI `App`: the whole application is a status item and a
/// panel, and `MenuBarExtra` cannot be opened from a global shortcut, kept open across a
/// save panel, or given focus for a PIN field — the three things this app needs most.
/// The executable target does nothing but hand an instance of this to `NSApplication`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = HUDStore()
    private lazy var hud = HUDController(store: store)

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(store.preferences.showInDock ? .regular : .accessory)
        installMainMenu()
        hud.installStatusItem()

        store.preferences.onHotkeyChanged = { [weak self] in self?.applyHotkey() }
        store.preferences.onShowInDockChanged = { showInDock in
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        }
        applyHotkey()

        Task {
            await store.refresh()
            // Starting is not an event: the app appears in the menu bar and waits. Only the
            // very first run explains itself, and only because a menu-bar app with no Dock
            // icon is otherwise impossible to find.
            if !store.preferences.hasOnboarded {
                AuxiliaryWindows.shared.showOnboarding(store: store) { [weak self] in
                    // Finishing onboarding is a deliberate click, so the panel opens once —
                    // anchored under its icon, which is the thing being taught.
                    self?.hud.show()
                }
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Quitting is not a reason to leave a derived password behind on the clipboard.
        store.generation.clearClipboard()
        GlobalHotkeyService.shared.unregister()
    }

    private func applyHotkey() {
        GlobalHotkeyService.shared.unregister()
        // Nothing is registered while the user is typing a replacement.
        guard !store.preferences.isRecordingHotkey else { return }
        guard store.preferences.hotkeyEnabled else {
            store.preferences.hotkeyRegistrationFailed = false
            return
        }
        let registered = GlobalHotkeyService.shared.register(store.preferences.hotkey) { [weak self] in
            Task { @MainActor in self?.hud.toggle() }
        }
        store.preferences.hotkeyRegistrationFailed = !registered
        if !registered {
            store.errorText = "The shortcut \(store.preferences.hotkey.display) is already taken by another application."
        }
    }

    /// A minimal main menu.
    ///
    /// Without it the panel's text fields lose ⌘V, ⌘A and friends — the Edit menu is what
    /// supplies those responders — and ⌘Q would do nothing while the HUD is key.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FidoPass", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let preferences = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        let manager = NSMenuItem(title: "Manager…", action: #selector(showManager), keyEquivalent: "k")
        manager.keyEquivalentModifierMask = [.command, .shift]
        manager.target = self
        appMenu.addItem(manager)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FidoPass", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit FidoPass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showManager() {
        AuxiliaryWindows.shared.showAuthenticatorManager(store: store)
    }

    @objc private func showPreferences() {
        AuxiliaryWindows.shared.showPreferences(store: store)
    }
}
