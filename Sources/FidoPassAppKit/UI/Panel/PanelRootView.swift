import SwiftUI
import FidoPassCore

/// Everything the menu-bar panel shows.
///
/// The sub-stores are observed explicitly: they are separate objects precisely so that a
/// clipboard countdown ticking once a second does not redraw the whole panel.
struct PanelRootView: View {
    @ObservedObject var store: PanelStore
    @ObservedObject private var devices: DeviceStore
    @ObservedObject private var accounts: AccountStore
    @ObservedObject private var generation: GenerationStore
    @ObservedObject private var labels: LabelStore
    @ObservedObject private var touchGate: TouchGate
    @ObservedObject private var labelEditor: LabelEditor

    init(store: PanelStore) {
        self.store = store
        self.touchGate = store.touchGate
        self.labelEditor = store.labelEditor
        self.devices = store.devices
        self.accounts = store.accounts
        self.generation = store.generation
        self.labels = store.labels
    }

    var body: some View {
        VStack(spacing: 0) {
            if let touch = touchGate.panelPrompt {
                TouchOverlayView(prompt: touch, onCancel: touchGate.abandonTouch)
            } else if touchGate.isWorking, let title = touchGate.panelBusyTitle {
                PanelWaitingView(title: title, message: store.selectedDevice?.displayName)
            } else {
                PanelHeaderView(store: store, devices: devices, accounts: accounts)
                Divider()
                content
                // One strip at the bottom: what just happened, or — when nothing did — what
                // the keyboard can do here.
                if store.statusText != nil || store.error != nil {
                    PanelFooterView(status: store.statusText,
                                    error: store.error,
                                    retriesRemaining: devices.selectedState?.pinRetriesRemaining)
                } else {
                    PanelHintsView(hints: store.keyboardHints)
                }
            }
        }
        .frame(width: PanelMetrics.width)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PanelMetrics.corner, style: .continuous)
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
                    .frame(maxHeight: PanelMetrics.maxContentHeight)
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
            if store.effectiveRoute == .accounts, !labelEditor.isEditing {
                Button("") { store.moveSelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { store.moveSelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { labelEditor.moveFocus(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { labelEditor.moveFocus(by: -1) }
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
