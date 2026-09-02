import SwiftUI
import FidoPassCore

/// Everything the menu-bar panel shows.
///
/// The sub-stores are observed explicitly: they are separate objects precisely so that a
/// clipboard countdown ticking once a second does not redraw the whole panel.
struct HUDRootView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject private var devices: DeviceStore
    @ObservedObject private var accounts: AccountStore
    @ObservedObject private var generation: GenerationStore
    @ObservedObject private var labels: LabelStore

    init(store: HUDStore) {
        self.store = store
        self.devices = store.devices
        self.accounts = store.accounts
        self.generation = store.generation
        self.labels = store.labels
    }

    var body: some View {
        VStack(spacing: 0) {
            if let touch = store.touch {
                TouchOverlayView(prompt: touch, onCancel: store.abandonTouch)
            } else if store.isWorking, let title = store.busyTitle {
                HUDWaitingView(title: title, message: store.selectedDevice?.displayName)
            } else {
                HUDHeaderView(store: store, devices: devices, accounts: accounts)
                Divider()
                content
                // One strip at the bottom: what just happened, or — when nothing did — what
                // the keyboard can do here.
                if store.statusText != nil || store.errorText != nil {
                    HUDFooterView(status: store.statusText, error: store.errorText)
                } else {
                    HUDHintsView(hints: store.keyboardHints)
                }
            }
        }
        .frame(width: HUDMetrics.width)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: HUDMetrics.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HUDMetrics.corner, style: .continuous)
                .stroke(Color.primary.opacity(0.12))
        }
        .background { keyboardShortcuts }
    }

    @ViewBuilder
    private var content: some View {
        // Never `store.route`: the panel is drawn the moment it opens, before the refresh
        // that would correct a stale route has finished.
        switch store.effectiveRoute {
        case .accounts:
            if devices.devices.isEmpty {
                NoKeyView(isRefreshing: devices.isRefreshing) { Task { await store.refresh() } }
            } else {
                ScrollView { AccountsSectionView(store: store, accounts: accounts, generation: generation, labels: labels) }
                    .frame(maxHeight: HUDMetrics.maxContentHeight)
            }
        case .unlock:
            UnlockView(store: store, devices: devices)
        case .setPIN:
            SetPINView(store: store)
        case .pinChangeRequired:
            PINChangeRequiredView(store: store)
        case .enroll:
            EnrollView(store: store)
        case .backupKey(let ref):
            BackupKeyView(store: store, ref: ref)
        case .confirmDelete(let ref):
            ConfirmDeleteView(store: store, ref: ref)
        }
    }

    /// Keyboard paths for everything the mouse can do. Invisible buttons are the only way to
    /// attach shortcuts to a panel that is not a document window.
    ///
    /// Plain `Return` is deliberately absent: it belongs to each screen's own primary button
    /// (`.defaultAction`). A global one fired *in addition* to the focused field's submit
    /// action, which spent two PIN attempts on a single keypress.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { Task { await store.revealPassword(for: store.selection) } }
                .keyboardShortcut(.return, modifiers: [.command])

            // While the custom-label field has the keyboard, the arrows are its own: it
            // forwards up and down back here, and hands left back only from the caret's
            // starting position.
            if store.effectiveRoute == .accounts, !store.isEditingLabel {
                Button("") { store.moveSelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { store.moveSelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { store.moveLabelFocus(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { store.moveLabelFocus(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            Button("") { store.show(.enroll) }
                .keyboardShortcut("n", modifiers: [.command])
            Button("") { if let ref = store.selection { Task { await store.openEncryptEditor(for: ref) } } }
                .keyboardShortcut("e", modifiers: [.command])
            Button("") { store.lockSelectedKey() }
                .keyboardShortcut("l", modifiers: [.command])
            Button("") { Task { await store.refresh() } }
                .keyboardShortcut("r", modifiers: [.command])
            ForEach(1...3, id: \.self) { number in
                Button("") { store.selectAccount(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [.command])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

struct HUDHeaderView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject var devices: DeviceStore
    @ObservedObject var accounts: AccountStore

    var body: some View {
        HStack(spacing: 9) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if devices.devices.count > 1 { keySwitcher }

            if store.isSelectedKeyUnlocked {
                Button(action: store.lockSelectedKey) {
                    Image(systemName: "lock.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Lock this key now (⌘L)")
            }

            Menu {
                Button("New account…") { store.show(.enroll) }
                    .disabled(!store.isSelectedKeyUnlocked)
                Button("Manager…") { store.openManager() }
                    .disabled(devices.devices.isEmpty)
                Button("Refresh") { Task { await store.refresh() } }
                Divider()
                Button("Lock now") { store.lockSelectedKey() }
                    .disabled(!store.isSelectedKeyUnlocked)
                Divider()
                Button("Preferences…") { AuxiliaryWindows.shared.showPreferences(store: store) }
                Button("Quit FidoPass") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Key and application actions")
        }
        .padding(.horizontal, HUDMetrics.padding)
        .padding(.vertical, 9)
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 28, height: 28)
            Image(systemName: store.isSelectedKeyUnlocked ? "key.fill" : "key.slash.fill")
                .font(.system(size: 12))
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        guard let device = store.selectedDevice else { return .secondary }
        return store.isSelectedKeyUnlocked ? DeviceColorPalette.color(for: device) : .orange
    }

    private var title: String {
        store.selectedDevice?.displayName ?? "No security key"
    }

    private var subtitle: String {
        guard let device = store.selectedDevice else { return "Connect a key over USB or NFC" }
        guard store.isSelectedKeyUnlocked else { return "Locked — PIN required" }
        let count = accounts.accounts(onDevice: device.path).count
        return count == 1 ? "Unlocked · 1 account" : "Unlocked · \(count) accounts"
    }

    private var keySwitcher: some View {
        HStack(spacing: 3) {
            ForEach(devices.devices, id: \.path) { device in
                Button {
                    store.selectKey(path: device.path)
                } label: {
                    Image(systemName: devices.state(for: device.path)?.unlocked == true ? "key.fill" : "key.slash.fill")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(device.path == devices.selectedPath ? Color.accentColor.opacity(0.2) : .clear)
                }
                .help(device.displayName)
            }
        }
    }
}

struct NoKeyView: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void

    /// Re-checks while this screen is on display. A key that is re-enumerating after a touch
    /// comes back within a second or two, and waiting for the user to discover a button
    /// would make a blip look like a dead application.
    private let retry = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No security key connected")
                .font(.system(size: 13, weight: .semibold))
            Text("FidoPass keeps nothing on this Mac — the accounts live on the key, and a password exists only while it is on screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Look again")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .onReceive(retry) { _ in if !isRefreshing { onRefresh() } }
    }
}
