import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The settings window.
///
/// Every explanation lives in its section's footer rather than in a row of its own: a row is
/// laid out against the form's label column and gets squeezed, a footer is free to wrap.
struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var labels: LabelStore
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle("Open with a global shortcut", isOn: $preferences.hotkeyEnabled)
                LabeledContent("Shortcut") {
                    HotkeyRecorderView(preferences: preferences)
                }
                .disabled(!preferences.hotkeyEnabled)

                if preferences.hotkeyRegistrationFailed, preferences.hotkeyEnabled {
                    Label("\(preferences.hotkey.display) is already taken by another application. Pick a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Opens the HUD from any application. Registered without asking for Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Lock the key after", selection: $preferences.lockTimeout) {
                    ForEach(Preferences.lockTimeoutChoices, id: \.self) { timeout in
                        Text(Self.timeoutLabel(timeout)).tag(timeout)
                    }
                }
            } header: {
                Text("Security")
            } footer: {
                Text("The PIN is held in memory only while the key is unlocked, and every use of the key starts the countdown again. Locking your Mac or unplugging the key locks it immediately, whatever this says.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Preselect the last account and label", isOn: $preferences.rememberLastUsed)

                LabeledContent("Preselected") {
                    HStack(spacing: 8) {
                        Text(preselectionDescription)
                            .foregroundStyle(.secondary)
                        if preferences.lastUsed != nil {
                            Button("Forget") { preferences.forgetLastUsed() }
                        }
                    }
                }
            } header: {
                Text("What FidoPass remembers")
            } footer: {
                Text("The one account and label the HUD opens on, so the usual password is one keypress away. Stored on this Mac only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if labels.histories.isEmpty {
                    Text("No labels used yet")
                        .foregroundStyle(.secondary)
                } else {
                    // Grouped by key, not listed flat: the same account id legitimately
                    // lives on two keys — that is what a portable backup looks like — and
                    // the two histories are different lists of labels.
                    ForEach(keyGroups) { group in
                        if keyGroups.count > 1 {
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.entries) { entry in
                            LabeledContent {
                                Text(entry.labels.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            } label: {
                                Text(entry.accountId)
                                    .padding(.leading, keyGroups.count > 1 ? 10 : 0)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Clear label history") { labels.clearAll() }
                    }
                }
            } header: {
                Text("Label history")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Labels are kept per account — offered under another account, a label would derive a password that is valid and wrong. They sync through iCloud when available, together with the account ids they are grouped by.")
                    Text("Nothing here is a secret: no password, PIN or backup key is written anywhere. But a forgotten label makes its password unreproducible even with the key in hand, which is what the recovery sheet is for.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin },
                                                        set: { newValue in
                                                            launchAtLogin = newValue
                                                            preferences.launchAtLogin = newValue
                                                        }))
                Toggle("Show in Dock", isOn: $preferences.showInDock)
            } header: {
                Text("Startup")
            } footer: {
                Text("FidoPass lives in the menu bar. Without launch at login the shortcut only works once you have started the app by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { launchAtLogin = preferences.launchAtLogin }
    }

    /// One key's histories, under the name that key gave when they were recorded — which is
    /// the only name available while the key itself is in a drawer.
    private struct KeyGroup: Identifiable {
        let signature: String
        let title: String
        let entries: [LabelStore.Entry]
        var id: String { signature }
    }

    private var keyGroups: [KeyGroup] {
        var order: [String] = []
        var byKey: [String: [LabelStore.Entry]] = [:]
        for entry in labels.histories {
            // A history from a key that never named itself is still shown; it is grouped
            // under the signature it was written with, and under nothing if it has none.
            let signature = entry.deviceSignature ?? ""
            if byKey[signature] == nil { order.append(signature) }
            byKey[signature, default: []].append(entry)
        }
        return order.map { signature in
            let entries = byKey[signature] ?? []
            let name = entries.compactMap(\.deviceName).first
            switch (name, signature.isEmpty) {
            case (let name?, false): return KeyGroup(signature: signature, title: name, entries: entries)
            case (let name?, true):  return KeyGroup(signature: signature, title: name, entries: entries)
            case (nil, false):       return KeyGroup(signature: signature, title: signature, entries: entries)
            case (nil, true):        return KeyGroup(signature: signature, title: "Unknown key", entries: entries)
            }
        }
    }

    private static func timeoutLabel(_ timeout: TimeInterval) -> String {
        let minutes = Int(timeout / 60)
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private var preselectionDescription: String {
        guard preferences.rememberLastUsed else { return "off" }
        guard let lastUsed = preferences.lastUsed else { return "nothing yet" }
        return "\(lastUsed.accountId) · “\(lastUsed.label)”"
    }
}

/// Records a key combination by watching the next key press.
///
/// Sized and bordered like a control rather than drawn as a row of its own: inside a form it
/// sits in the value column, where a shortcut field belongs.
struct HotkeyRecorderView: View {
    @ObservedObject var preferences: Preferences
#if canImport(AppKit)
    @State private var monitor: Any?
#endif

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
#if canImport(AppKit)
        .onDisappear(perform: stop)
#endif
    }

    private func start() {
#if canImport(AppKit)
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
#endif
    }

    private func stop() {
#if canImport(AppKit)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Re-registers whatever the combination now is — the new one, or the old one when
        // the recording was cancelled.
        preferences.isRecordingHotkey = false
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
        // Without a modifier the shortcut would fire while typing in any other application.
        guard carbon != 0 else { return nil }
        let character = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !character.isEmpty, character.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon, display: display + character)
    }
#endif
}
