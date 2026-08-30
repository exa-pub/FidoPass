import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var labels: LabelStore
    @State private var launchAtLogin: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Global shortcut", isOn: $preferences.hotkeyEnabled)
                HotkeyRecorderView(combo: $preferences.hotkey)
                    .disabled(!preferences.hotkeyEnabled)
                Text("Opens the HUD from any application. Registered without Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shortcut")
            }

            Section {
                Toggle("Close the HUD after copying", isOn: $preferences.autoCloseAfterCopy)
                Toggle("Remember the last account and label", isOn: $preferences.rememberLastUsed)
                Text("Remembering costs one thing: the account id is written to this Mac's preferences. Nothing else about it is — no password, PIN or backup key ever leaves the key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preferences.lastUsed != nil {
                    Button("Forget last used") { preferences.forgetLastUsed() }
                        .controlSize(.small)
                }
            } header: {
                Text("Behaviour")
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin },
                                                        set: { newValue in
                                                            launchAtLogin = newValue
                                                            preferences.launchAtLogin = newValue
                                                        }))
                Toggle("Show in Dock", isOn: $preferences.showInDock)
                Text("FidoPass lives in the menu bar. Without launch at login the global shortcut only works after you start it by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Startup")
            }

            Section {
                Text(labels.recent.isEmpty ? "No labels recorded yet." : labels.recent.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Clear label history") { labels.clearRecent() }
                    .controlSize(.small)
                    .disabled(labels.recent.isEmpty)
                Text("Labels are not secret, but forgetting one makes its password unreproducible. The recovery sheet exists to keep a copy off this machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Labels")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { launchAtLogin = preferences.launchAtLogin }
    }
}

/// Records a key combination by watching the next key press.
struct HotkeyRecorderView: View {
    @Binding var combo: HotkeyCombo
    @State private var isRecording = false
#if canImport(AppKit)
    @State private var monitor: Any?
#endif

    var body: some View {
        HStack {
            Text("Shortcut")
            Spacer()
            Button(isRecording ? "Press keys…" : combo.display) {
                isRecording ? stop() : start()
            }
            .frame(width: 130)
        }
#if canImport(AppKit)
        .onDisappear(perform: stop)
#endif
    }

    private func start() {
#if canImport(AppKit)
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let recorded = HotkeyRecorderView.combo(from: event) else { return event }
            combo = recorded
            stop()
            return nil
        }
#endif
    }

    private func stop() {
#if canImport(AppKit)
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
#endif
    }

#if canImport(AppKit)
    static func combo(from event: NSEvent) -> HotkeyCombo? {
        var carbon: UInt32 = 0
        var display = ""
        if event.modifierFlags.contains(.control) { carbon |= 0x1000; display += "⌃" }
        if event.modifierFlags.contains(.option)  { carbon |= 0x0800; display += "⌥" }
        if event.modifierFlags.contains(.shift)   { carbon |= 0x0200; display += "⇧" }
        if event.modifierFlags.contains(.command) { carbon |= 0x0100; display += "⌘" }
        // A shortcut without modifiers would fire while typing in any other application.
        guard carbon != 0 else { return nil }
        let character = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !character.isEmpty else { return nil }
        return HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon, display: display + character)
    }
#endif
}
