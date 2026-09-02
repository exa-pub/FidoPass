import Combine
import Foundation

/// Keeps the system-wide shortcut in step with what Preferences says it should be.
///
/// The two pieces of state here are transient — whether the last registration failed, and
/// whether the settings window is currently capturing a new combination — which is why they
/// live next to the registrar rather than in `Preferences`, whose job is what survives a
/// relaunch.
@MainActor
final class HotkeyRegistration: ObservableObject {

    /// Set when the system refused to register the shortcut — almost always because another
    /// application already owns it.
    @Published private(set) var registrationFailed = false

    /// True while the settings window is capturing a new combination.
    ///
    /// The global shortcut is released meanwhile: Carbon dispatches a registered hot key
    /// before any window sees the key, so pressing the *current* combination would fire the
    /// HUD instead of being recorded as the new one.
    @Published var isRecording = false {
        didSet { apply(preferences.hotkey, enabled: preferences.hotkeyEnabled) }
    }

    private let preferences: Preferences
    private let registrar: HotkeyRegistrar
    private let onPress: @MainActor () -> Void
    private var subscriptions: Set<AnyCancellable> = []

    init(preferences: Preferences, registrar: HotkeyRegistrar, onPress: @escaping @MainActor () -> Void) {
        self.preferences = preferences
        self.registrar = registrar
        self.onPress = onPress
        // The published values are used rather than re-read from `preferences`: a `@Published`
        // property publishes from `willSet`, so the stored value is still the old one when
        // this runs.
        Publishers.CombineLatest(preferences.$hotkey, preferences.$hotkeyEnabled)
            .dropFirst()
            .sink { [weak self] combo, enabled in self?.apply(combo, enabled: enabled) }
            .store(in: &subscriptions)
        apply(preferences.hotkey, enabled: preferences.hotkeyEnabled)
    }

    private func apply(_ combo: HotkeyCombo, enabled: Bool) {
        registrar.unregister()
        // Nothing is registered while the user is typing a replacement.
        guard !isRecording else { return }
        guard enabled else {
            registrationFailed = false
            return
        }
        registrationFailed = !registrar.register(combo, onPress: onPress)
    }
}
