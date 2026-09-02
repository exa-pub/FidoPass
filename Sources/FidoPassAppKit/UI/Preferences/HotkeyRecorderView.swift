import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Records a key combination by watching the next key press.
///
/// Sized and bordered like a control rather than drawn as a row of its own: inside a form it
/// sits in the value column, where a shortcut field belongs.
struct HotkeyRecorderView: View {
    @ObservedObject var preferences: Preferences
    @State private var monitor: Any?

    private var isRecording: Bool { preferences.isRecordingHotkey }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press keys…" : preferences.hotkey.display)
                    .font(.system(size: 12, design: isRecording ? .default : .monospaced))
                    .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                    .frame(width: 96)
            }
            .help(isRecording ? "Press the combination, or Escape to cancel" : "Click, then press a new combination")

            Button("Reset") { preferences.hotkey = .default }
                .disabled(preferences.hotkey == .default || isRecording)
                .help("Back to \(HotkeyCombo.default.display)")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        // Releases the global shortcut, so pressing the current combination records it
        // instead of firing it.
        preferences.isRecordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape leaves the old combination alone rather than recording an unusable one.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            guard let recorded = HotkeyRecorderView.combo(from: event) else { return nil }
            preferences.hotkey = recorded
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Re-registers whatever the combination now is — the new one, or the old one when
        // the recording was cancelled.
        preferences.isRecordingHotkey = false
    }

    static func combo(from event: NSEvent) -> HotkeyCombo? {
        var carbon: UInt32 = 0
        var display = ""
        if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey); display += "⌃" }
        if event.modifierFlags.contains(.option)  { carbon |= UInt32(optionKey); display += "⌥" }
        if event.modifierFlags.contains(.shift)   { carbon |= UInt32(shiftKey); display += "⇧" }
        if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey); display += "⌘" }
        // Without a modifier the shortcut would fire while typing in any other application.
        guard carbon != 0 else { return nil }
        let character = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !character.isEmpty, character.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon, display: display + character)
    }
}
