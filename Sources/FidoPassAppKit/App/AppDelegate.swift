import AppKit
import Combine
#if FIDOPASS_VIRTUAL_KEYS
import FidoPassVirtualKeys
#endif

/// AppKit entry point. The custom HUD supports global shortcuts, PIN focus and save panels.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private let windows = AppWindows()
    private let updates: any UpdateService
    #if FIDOPASS_VIRTUAL_KEYS
    private let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/fidopass-test-authenticator")
    private lazy var virtualRegistry = VirtualDeviceRegistry(executable: helperURL)
    private lazy var container = AppContainer(backend: LiveKeyBackend(core: virtualRegistry.core),
                                               router: windows, updates: updates,
                                               emptyConfirmationDelay: .zero,
                                               enableDeviceMonitor: false)
    private lazy var virtualDevices = VirtualDeviceStore(registry: virtualRegistry, devices: container.devices,
                                                        executable: helperURL)
    private lazy var virtualWindow = VirtualDevicesController(store: virtualDevices)
    #else
    private lazy var container = AppContainer(router: windows, updates: updates)
    #endif
    private lazy var hud = PanelController(container: container)
    private lazy var hotkey = HotkeyRegistration(preferences: container.preferences,
                                                 registrar: GlobalHotkeyService()) { [weak self] in
        self?.hud.toggle()
    }
    private lazy var auxiliary = AuxiliaryWindows(container: container,
                                                  hotkey: hotkey,
                                                  launchAtLogin: SMAppLaunchAtLogin())
    private var subscriptions: Set<AnyCancellable> = []

    /// - Parameter updates: the updater; `FidoPassMain` passes the Sparkle-backed one.
    public init(updates: any UpdateService) {
        self.updates = updates
        super.init()
    }

    /// A delegate that cannot update — what the tests build.
    public override convenience init() {
        self.init(updates: UnavailableUpdateService())
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        windows.panel = hud
        windows.auxiliary = auxiliary
        windows.container = container

        let preferences = container.preferences
        NSApp.setActivationPolicy(preferences.showInDock ? .regular : .accessory)
        preferences.$showInDock
            .dropFirst()
            .sink { NSApp.setActivationPolicy($0 ? .regular : .accessory) }
            .store(in: &subscriptions)
        installMainMenu()
        hud.installStatusItem()
        #if FIDOPASS_VIRTUAL_KEYS
        windows.virtualDevices = virtualWindow
        hud.virtualDevicesWindow = { [weak self] in self?.virtualWindow.window }
        virtualWindow.show()
        #endif
        // Registers the shortcut, and keeps it registered as Preferences change.
        _ = hotkey

        Task {
            await container.panel.refresh()
            // Starting is not an event: the app appears in the menu bar and waits. Only the
            // very first run explains itself, and only because a menu-bar app with no Dock
            // icon is otherwise impossible to find.
            if !preferences.hasOnboarded {
                auxiliary.showOnboarding { [weak self] in
                    // Finishing onboarding is a deliberate click, so the panel opens once —
                    // anchored under its icon, which is the thing being taught.
                    self?.hud.show()
                }
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        container.temporaryUV.stop()
        // Quitting is not a reason to leave a derived password behind on the clipboard.
        container.generation.clearClipboard()
        #if FIDOPASS_VIRTUAL_KEYS
        virtualRegistry.stop()
        #endif
    }

    /// A minimal main menu.
    ///
    /// Without it the panel's text fields lose ⌘V, ⌘A and friends — the Edit menu is what
    /// supplies those responders. File > Close routes ⌘W through the key window, including
    /// floating panels, so their normal close delegates still run.
    func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FidoPass", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        appMenu.addItem(updatesItem)
        appMenu.addItem(.separator())
        let preferences = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        let manager = NSMenuItem(title: "Manager…", action: #selector(showManager), keyEquivalent: "k")
        manager.keyEquivalentModifierMask = [.command, .shift]
        manager.target = self
        appMenu.addItem(manager)
        #if FIDOPASS_VIRTUAL_KEYS
        let virtual = NSMenuItem(title: "Virtual Devices…", action: #selector(showVirtualDevices), keyEquivalent: "")
        virtual.target = self
        appMenu.addItem(virtual)
        #endif
        let encrypt = NSMenuItem(title: "Encrypt a message…", action: #selector(encryptMessage), keyEquivalent: "e")
        encrypt.keyEquivalentModifierMask = [.command, .shift]
        encrypt.target = self
        appMenu.addItem(encrypt)
        let decrypt = NSMenuItem(title: "Decrypt a message…", action: #selector(decryptMessage), keyEquivalent: "d")
        decrypt.keyEquivalentModifierMask = [.command, .shift]
        decrypt.target = self
        appMenu.addItem(decrypt)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FidoPass", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit FidoPass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

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

    #if FIDOPASS_VIRTUAL_KEYS
    @objc private func showVirtualDevices() { windows.openVirtualDevices() }
    #endif

    @objc private func showManager() {
        auxiliary.showAuthenticatorManager()
    }

    @objc private func showPreferences() {
        auxiliary.showPreferences()
    }

    /// No window of its own: the result is a line in Preferences, which this opens.
    @objc private func checkForUpdates() {
        auxiliary.showPreferences()
        container.updates.checkForUpdates()
    }

    @objc private func encryptMessage() {
        container.panel.openEncryptor()
    }

    @objc private func decryptMessage() {
        container.panel.openDecryptor()
    }

    /// Opening messages needs the selected key unlocked; the item is disabled until then.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(decryptMessage) {
            return container.panel.isSelectedKeyUnlocked
        }
        if menuItem.action == #selector(checkForUpdates) {
            return updates.isAvailable
        }
        return true
    }

    // MARK: - fidopass:// links

    /// A link clicked in a browser, a chat, a mail. Registered in `Info.plist` by
    /// `build_app.sh`. The container reads it and opens a window with it; nothing about a
    /// link ever touches the security key — see `IncomingLink`.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            container.openLink(url)
        }
    }
}
