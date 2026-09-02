#if canImport(AppKit)
import AppKit
import SwiftUI

/// The windows that are not the HUD.
///
/// The text editor is a window by nature — its whole point is to sit beside the application
/// you are pasting into, which a popover cannot do. Preferences and onboarding are rare and
/// wordy, and would make the HUD something it should not be.
@MainActor
final class AuxiliaryWindows {

    static let shared = AuxiliaryWindows()

    private var editorWindow: NSWindow?
    private var editorSession: CryptoEditorSession?
    private var preferencesWindow: NSWindow?
    private var managerWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var delegates: [ObjectIdentifier: WindowCloseDelegate] = [:]

    private init() {}

    // MARK: - Text editor

    func showEditor(session: CryptoEditorSession, onClosed: @escaping () -> Void = {}) {
        closeEditor()
        editorSession = session

        let view = CryptoEditorView(session: session,
                                    onCopyPlaintext: { text in
                                        ClipboardService.copySecret(text)
                                    },
                                    onCopyCiphertext: { text in
                                        // Not a secret, and it exists to be pasted elsewhere:
                                        // wiping it mid-paste would be a defect, not protection.
                                        ClipboardService.copySecret(text, clearAfter: 0)
                                    })
        let window = makeWindow(title: "Encrypt text — \(session.accountId) · “\(session.label)”",
                                content: AnyView(view),
                                size: NSSize(width: 820, height: 440),
                                resizable: true)
        onClose(of: window) { [weak self] in
            self?.editorSession?.close()
            self?.editorSession = nil
            self?.editorWindow = nil
            onClosed()
        }
        editorWindow = window
        present(window)
    }

    func closeEditor() {
        editorSession?.close()
        editorSession = nil
        editorWindow?.close()
        editorWindow = nil
    }

    // MARK: - Preferences

    func showPreferences(store: HUDStore) {
        if let preferencesWindow {
            present(preferencesWindow)
            return
        }
        let window = makeWindow(title: "FidoPass Settings",
                                content: AnyView(PreferencesView(preferences: store.preferences, labels: store.labels)),
                                size: nil,
                                resizable: false)
        onClose(of: window) { [weak self] in self?.preferencesWindow = nil }
        preferencesWindow = window
        present(window)
    }

    // MARK: - FIDO manager

    /// The manager is a window rather than a HUD screen: the panel is 340pt wide and
    /// optimised for the shortest path to a password, and a table of every credential on a
    /// key is neither of those things.
    func showAuthenticatorManager(store: HUDStore) {
        if let managerWindow {
            present(managerWindow)
            return
        }
        let window = makeWindow(title: "FIDO Manager",
                                content: AnyView(AuthenticatorManagerView(store: store)),
                                size: NSSize(width: 960, height: 620),
                                resizable: true)
        onClose(of: window) { [weak self] in self?.managerWindow = nil }
        managerWindow = window
        present(window)
    }

    // MARK: - Onboarding

    func showOnboarding(store: HUDStore, onFinish: @escaping () -> Void) {
        if let onboardingWindow {
            present(onboardingWindow)
            return
        }
        let window = makeWindow(title: "Welcome to FidoPass",
                                content: AnyView(OnboardingView(preferences: store.preferences, onFinish: {
                                    onFinish()
                                    AuxiliaryWindows.shared.closeOnboarding()
                                })),
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
        let delegate = WindowCloseDelegate(action: action)
        delegates[ObjectIdentifier(window)] = delegate
        window.delegate = delegate
    }
}

private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func windowWillClose(_ notification: Notification) {
        action()
    }
}
#endif
