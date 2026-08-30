#if canImport(AppKit)
import AppKit

/// Entry point.
///
/// Plain AppKit rather than a SwiftUI `App`: the whole application is a status item and a
/// panel, and `MenuBarExtra` cannot be opened from a global shortcut, kept open across a
/// save panel, or given focus for a PIN field — the three things this app needs most.
@main
enum FidoPassMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = HUDStore()
    private lazy var hud = HUDController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            if !store.preferences.hasOnboarded {
                AuxiliaryWindows.shared.showOnboarding(store: store) { [weak self] in
                    self?.hud.show()
                }
            } else if !store.preferences.launchAtLogin {
                // Started by hand: show the HUD once, or a menu-bar app with no Dock icon is
                // invisible to the person who just launched it. A login-item launch gets
                // nothing — that one happens while the user is doing something else.
                hud.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting is not a reason to leave a derived password behind on the clipboard.
        store.generation.clearClipboard()
        GlobalHotkeyService.shared.unregister()
    }

    private func applyHotkey() {
#if canImport(Carbon)
        GlobalHotkeyService.shared.unregister()
        guard store.preferences.hotkeyEnabled else { return }
        let registered = GlobalHotkeyService.shared.register(store.preferences.hotkey) { [weak self] in
            Task { @MainActor in self?.hud.toggle() }
        }
        if !registered {
            store.errorText = "The shortcut \(store.preferences.hotkey.display) is already taken by another application."
        }
#endif
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

    @objc private func showPreferences() {
        AuxiliaryWindows.shared.showPreferences(store: store)
    }
}
#endif
