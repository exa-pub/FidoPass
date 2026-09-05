import AppKit
import FidoPassCore
import SwiftUI

/// The windows that are not the HUD.
///
/// The message windows are windows by nature — their whole point is to sit beside the
/// application you are pasting into, which a popover cannot do. Preferences and onboarding
/// are rare and wordy, and would make the HUD something it should not be.
@MainActor
final class AuxiliaryWindows {

    private unowned let container: AppContainer
    private let hotkey: HotkeyRegistration
    private let launchAtLogin: LaunchAtLoginService

    private var encryptionKeyWindow: NSWindow?
    private var encryptorWindow: NSWindow?
    private var encryptStore: MessageEncryptStore?
    private var decryptorWindow: NSWindow?
    private var decryptStore: MessageDecryptStore?
    private var preferencesWindow: NSWindow?
    private var managerWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var delegates: [ObjectIdentifier: WindowCloseDelegate] = [:]

    init(container: AppContainer, hotkey: HotkeyRegistration, launchAtLogin: LaunchAtLoginService) {
        self.container = container
        self.hotkey = hotkey
        self.launchAtLogin = launchAtLogin
    }

    // MARK: - Messages

    func showEncryptionKey(_ key: EncryptionKeyURL, for account: Account) {
        encryptionKeyWindow?.close()
        let view = ShareEncryptionKeyView(key: key, account: account)
            .environment(\.clipboard, container.clipboard)
        let window = makeWindow(title: "Share encryption key", content: AnyView(view), size: nil, resizable: false)
        onClose(of: window) { [weak self] in self?.encryptionKeyWindow = nil }
        encryptionKeyWindow = window
        present(window)
    }

    /// A clicked recipient key fills the sender; issuing our own key never touches it.
    func showEncryptor(key: EncryptionKeyURL?) {
        if let encryptorWindow, let encryptStore {
            if let key { encryptStore.adopt(key) }
            present(encryptorWindow)
            return
        }
        let store = MessageEncryptStore(sealer: container.accounts.messages, prefilled: key)
        let view = EncryptMessageView(store: store)
            .environment(\.clipboard, container.clipboard)
        let window = makeWindow(title: "Encrypt a message",
                                content: AnyView(view),
                                size: NSSize(width: 640, height: 500),
                                resizable: true)
        onClose(of: window) { [weak self] in
            self?.encryptStore?.clear()
            self?.encryptStore = nil
            self?.encryptorWindow = nil
        }
        encryptStore = store
        encryptorWindow = window
        present(window)
    }

    /// The receiving window, over the store that binds it to a key. The coordinator decides
    /// when it closes; `onClosed` tells it the user did.
    func showDecryptor(store: MessageDecryptStore, onClosed: @escaping () -> Void) {
        if let decryptorWindow, decryptStore === store {
            present(decryptorWindow)
            return
        }
        closeDecryptor()
        decryptStore = store

        let view = DecryptMessageView(store: store, touchGate: container.touchGate)
            .environment(\.clipboard, container.clipboard)
        let window = makeWindow(title: "Decrypt a message — \(store.deviceName)",
                                content: AnyView(view),
                                size: NSSize(width: 640, height: 440),
                                resizable: true)
        onClose(of: window) { [weak self] in
            self?.decryptStore?.close()
            self?.decryptStore = nil
            self?.decryptorWindow = nil
            onClosed()
        }
        decryptorWindow = window
        present(window)
    }

    func closeDecryptor() {
        decryptStore?.close()
        decryptStore = nil
        decryptorWindow?.close()
        decryptorWindow = nil
    }

    // MARK: - Preferences

    func showPreferences() {
        if let preferencesWindow {
            present(preferencesWindow)
            return
        }
        let view = PreferencesView(preferences: container.preferences,
                                   labels: container.labels,
                                   hotkey: hotkey,
                                   launchAtLogin: launchAtLogin)
        let visible = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let window = makeWindow(title: "FidoPass Settings",
                                content: AnyView(view),
                                size: NSSize(width: 460, height: min(640, visible.height - 80)),
                                resizable: true)
        window.setFrame(WindowPlacement.clamped(window.frame, to: visible), display: false)
        onClose(of: window) { [weak self] in self?.preferencesWindow = nil }
        preferencesWindow = window
        present(window)
    }

    // MARK: - FIDO manager

    /// The manager is a window rather than a HUD screen: the panel is 340pt wide and
    /// optimised for the shortest path to a password, and a table of every credential on a
    /// key is neither of those things.
    func showAuthenticatorManager(devicePath: String? = nil) {
        Task { await container.manager.managerDidOpen(devicePath: devicePath) }
        if let managerWindow {
            present(managerWindow)
            return
        }
        let view = AuthenticatorManagerView(store: container.manager,
                                            devices: container.devices,
                                            inventory: container.inventory,
                                            touchGate: container.touchGate)
            .environment(\.clipboard, container.clipboard)
        let window = makeWindow(title: "FIDO Manager",
                                content: AnyView(view),
                                size: NSSize(width: 960, height: 620),
                                resizable: true)
        onClose(of: window) { [weak self] in
            self?.container.manager.managerDidClose()
            self?.managerWindow = nil
        }
        managerWindow = window
        present(window)
    }

    // MARK: - Onboarding

    func showOnboarding(onFinish: @escaping () -> Void) {
        if let onboardingWindow {
            present(onboardingWindow)
            return
        }
        let view = OnboardingView(preferences: container.preferences,
                                  launchAtLogin: launchAtLogin,
                                  onFinish: { [weak self] in
                                      onFinish()
                                      self?.closeOnboarding()
                                  })
        let window = makeWindow(title: "Welcome to FidoPass",
                                content: AnyView(view),
                                size: nil,
                                resizable: false)
        onClose(of: window) { [weak self] in self?.onboardingWindow = nil }
        onboardingWindow = window
        present(window)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Plumbing

    /// - Parameter size: an explicit content size, or nil to let the SwiftUI content decide.
    ///   Guessing a height is how a settings form ends up clipped the moment it grows.
    private func makeWindow(title: String, content: AnyView, size: NSSize?, resizable: Bool) -> NSWindow {
        let controller = NSHostingController(rootView: content)
        if size == nil { controller.sizingOptions = [.preferredContentSize] }

        // The style mask is set at construction rather than afterwards: changing it on a
        // live window re-lays out the content against the previous title-bar geometry, which
        // is how a window ends up looking a few points wrong everywhere.
        let style: NSWindow.StyleMask = resizable
            ? [.titled, .closable, .miniaturizable, .resizable]
            : [.titled, .closable]
        let contentSize = size ?? controller.view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: style,
                              backing: .buffered,
                              defer: false)
        window.contentViewController = controller
        window.title = title
        window.setContentSize(contentSize)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Accessory apps have no windows in front by default, so a new one would open behind
    /// whatever the user is looking at.
    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func onClose(of window: NSWindow, perform action: @escaping () -> Void) {
        let id = ObjectIdentifier(window)
        let delegate = WindowCloseDelegate { [weak self] in
            action()
            self?.delegates.removeValue(forKey: id)
        }
        delegates[id] = delegate
        window.delegate = delegate
    }
}

@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func windowWillClose(_ notification: Notification) {
        action()
    }
}
