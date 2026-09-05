import XCTest
import TestSupport
@testable import FidoPassAppKit

/// The system shortcut follows Preferences, and is released while a new one is being typed.
@MainActor
final class HotkeyRegistrationTests: AppTestCase {

    @MainActor
    private final class FakeRegistrar: HotkeyRegistrar {
        var registered: [HotkeyCombo] = []
        var unregisterCount = 0
        var accepts = true

        func register(_ combo: HotkeyCombo, onPress: @escaping @MainActor () -> Void) -> Bool {
            registered.append(combo)
            return accepts
        }

        func unregister() { unregisterCount += 1 }
    }

    private func preferences() -> Preferences {
        let suite = "HotkeyRegistrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Preferences(defaults: defaults)
    }

    func testTheStoredShortcutIsRegisteredAtOnce() {
        let registrar = FakeRegistrar()
        let registration = HotkeyRegistration(preferences: preferences(), registrar: registrar) {}
        XCTAssertEqual(registrar.registered, [.default])
        XCTAssertFalse(registration.registrationFailed)
    }

    /// Recording a new shortcut has to release the old one first: Carbon dispatches a
    /// registered hot key before any window sees the key, so pressing the current
    /// combination would fire the HUD instead of being recorded.
    func testRecordingReleasesTheShortcutAndFinishingAppliesTheNewOne() {
        let preferences = preferences()
        let registrar = FakeRegistrar()
        let registration = HotkeyRegistration(preferences: preferences, registrar: registrar) {}

        registration.isRecording = true
        XCTAssertEqual(registrar.registered.count, 1, "nothing may be registered while recording")
        XCTAssertGreaterThanOrEqual(registrar.unregisterCount, 2)

        let recorded = HotkeyCombo(keyCode: 4, modifiers: 0x0100, display: "⌘H")
        preferences.hotkey = recorded
        XCTAssertEqual(registrar.registered.count, 1, "still recording — still nothing registered")

        registration.isRecording = false
        XCTAssertEqual(registrar.registered.last, recorded, "finishing registers whatever the combination now is")
    }

    func testDisablingTheShortcutReleasesIt() {
        let preferences = preferences()
        let registrar = FakeRegistrar()
        let registration = HotkeyRegistration(preferences: preferences, registrar: registrar) {}
        let before = registrar.unregisterCount

        preferences.hotkeyEnabled = false

        XCTAssertGreaterThan(registrar.unregisterCount, before)
        XCTAssertEqual(registrar.registered.count, 1, "nothing new registered while disabled")
        XCTAssertFalse(registration.registrationFailed, "a disabled shortcut is not a failed one")
    }

    /// The only way the user learns another app owns the combination.
    func testARefusedRegistrationIsReported() {
        let registrar = FakeRegistrar()
        registrar.accepts = false
        let registration = HotkeyRegistration(preferences: preferences(), registrar: registrar) {}
        XCTAssertTrue(registration.registrationFailed)
    }
}
