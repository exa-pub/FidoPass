import SwiftUI
import AppKit

/// The settings window.
///
/// Every explanation lives in its section's footer rather than in a row of its own: a row is
/// laid out against the form's label column and gets squeezed, a footer is free to wrap.
struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var labels: LabelStore
    @ObservedObject var hotkey: HotkeyRegistration
    let launchAtLogin: LaunchAtLoginService
    @State private var confirmsClearHistory = false

    var body: some View {
        Form {
            Section {
                Toggle("Open with a global shortcut", isOn: $preferences.hotkeyEnabled)
                LabeledContent("Shortcut") {
                    HotkeyRecorderView(preferences: preferences, hotkey: hotkey)
                }
                .disabled(!preferences.hotkeyEnabled)

                if hotkey.registrationFailed, preferences.hotkeyEnabled {
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
                        Text(Preferences.timeoutLabel(timeout)).tag(timeout)
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
                Toggle("Preselect the last account", isOn: $preferences.rememberLastUsed)

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
                Text("The last selected credential. Label history is stored separately below. Stored on this Mac only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if !labels.hasHistory {
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
                                Text(entry.labels.map(LabelDisplay.text).joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            } label: {
                                Text(entry.accountId)
                                    .padding(.leading, keyGroups.count > 1 ? 10 : 0)
                            }
                        }
                    }

                    if labels.hasLegacyHistory {
                        Text("Unassigned labels from an earlier version are also stored on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Clear label history…") { confirmsClearHistory = true }
                    }
                }
            } header: {
                Text("Label history")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Label history is stored on this Mac, separately for each account.")
                    Text("Nothing here is a secret: no password, PIN or backup key is written anywhere. But a forgotten label makes its password unreproducible even with the key in hand, which is what the recovery sheet is for.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LaunchAtLoginToggle("Launch at login", service: launchAtLogin)
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
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        .alert("Clear label history?", isPresented: $confirmsClearHistory) {
            Button("Cancel", role: .cancel) {}
            Button("Clear history", role: .destructive) { labels.clearAll() }
        } message: {
            Text("This removes labels for \(labels.histories.count) account records\(labels.hasLegacyHistory ? " and unassigned legacy labels" : "") from this Mac. A forgotten label can make its password impossible to reproduce. Save the recovery sheets you need from each account’s menu first. Accounts on your keys are kept.")
        }
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

    private var preselectionDescription: String {
        guard preferences.rememberLastUsed else { return "off" }
        guard let lastUsed = preferences.lastUsed else { return "nothing yet" }
        return "\(lastUsed.accountId) · “\(lastUsed.label)”"
    }
}
