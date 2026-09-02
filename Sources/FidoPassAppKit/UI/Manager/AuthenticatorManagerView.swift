import SwiftUI
import FidoPassCore

/// The FIDO manager window: what is on the key, as the key describes it.
///
/// Deliberately without product framing. Relying parties are shown as they are — FidoPass's
/// own two sit in the same list as `github.com` — because the window's purpose is to show
/// the authenticator, not the app's view of it. The one exception is FidoPass portable key
/// material, which is withheld in the core; see `CredentialUserName`.
///
/// **Opening this window is the request to read** — see `ManagerStore.deviceDidAppear`. The
/// view only says when it appeared and which key it is looking at; the store decides.
struct AuthenticatorManagerView: View {
    @ObservedObject var store: ManagerStore
    @ObservedObject private var devices: DeviceStore
    @ObservedObject private var inventory: InventoryStore
    @ObservedObject private var touchGate: TouchGate

    init(store: ManagerStore, devices: DeviceStore, inventory: InventoryStore, touchGate: TouchGate) {
        self.store = store
        self.devices = devices
        self.inventory = inventory
        self.touchGate = touchGate
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if devices.devices.isEmpty {
                emptyState(title: "No security key connected", message: "Plug in a FIDO2 authenticator.")
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 190)
                    Divider()
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        // Keyed on the device so switching keys reads the one now on screen rather than
        // leaving the other one's answers up.
        .task(id: store.device?.path) { await store.deviceDidAppear() }
        .onChange(of: store.isUnlocked) { unlocked in
            guard unlocked else { return }
            Task { await store.keyDidUnlock() }
        }
        .sheet(item: $store.sheet) { which in
            switch which {
            case .changePIN:
                ManagerChangePINSheet(store: store, touchGate: touchGate)
            case .reset:
                ManagerResetSheet(store: store, touchGate: touchGate)
            }
        }
        .background {
            // No button for it: re-reading is rare, and a row of buttons was noise on a
            // window whose whole job is to be read.
            Button("") { Task { await store.read() } }
                .keyboardShortcut("r", modifiers: [.command])
                .opacity(0)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if devices.devices.count > 1 {
                    Picker("", selection: Binding(get: { store.device?.path ?? "" }, set: { store.chosenPath = $0 })) {
                        ForEach(devices.devices) { candidate in
                            Text(candidate.displayName).tag(candidate.path)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                } else if let device = store.device {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.displayName).font(.system(size: 13, weight: .semibold))
                        Text(device.identityLabel).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if store.reading.isReading || store.isApplying {
                    ProgressView().controlSize(.small)
                }
            }

            // Only the locked state earns a line. Unlocked is the ordinary case, and a badge
            // that is almost always present is a badge nobody reads.
            if !store.isUnlocked, !devices.devices.isEmpty {
                HStack(spacing: 6) {
                    Label("Key locked", systemImage: "lock").font(.caption)
                    Text("— credentials cannot be listed until it is.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Unlock…") { store.requestUnlock() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if let message = store.reading.infoError {
                Label(message.fullText(), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $store.tab) {
            ForEach(ManagerTab.allCases) { candidate in
                HStack {
                    Label(candidate.title, systemImage: candidate.symbol)
                    Spacer(minLength: 4)
                    if candidate == .credentials, let count = store.reading.inventory?.credentialCount {
                        Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .tag(candidate)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let reading = store.reading
        switch store.tab {
        case .overview:
            if let info = reading.info {
                ScrollView {
                    AuthenticatorOverviewView(info: info, inventory: reading.inventory)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                readingOrError
            }

        case .credentials:
            if let inventory = reading.inventory {
                CredentialsBrowserView(inventory: inventory, selection: $store.selectedCredential)
            } else if let message = reading.inventoryError {
                emptyState(title: "The credentials could not be read", message: message.fullText())
            } else if reading.needsUnlock {
                emptyState(title: "The key is locked", message: "Unlock it to list the credentials it holds.")
            } else {
                readingOrError
            }

        case .settings:
            if let info = reading.info {
                ScrollView {
                    AuthenticatorSettingsView(
                        info: info,
                        isUnlocked: store.isUnlocked,
                        onUnlock: { store.requestUnlock() },
                        onToggleAlwaysUV: { Task { await store.toggleAlwaysUV() } },
                        onRaiseMinimumPIN: { length in Task { await store.raiseMinimumPIN(to: length) } },
                        onForcePINChange: { Task { await store.forcePINChange() } },
                        onEnableEnterpriseAttestation: { Task { await store.enableEnterpriseAttestation() } },
                        onChangePIN: { store.beginChangePIN() },
                        onReset: { Task { await store.beginReset() } },
                        isBusy: store.isApplying || reading.isReading,
                        errorText: store.settingsError?.fullText())
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                readingOrError
            }
        }
    }

    @ViewBuilder
    private var readingOrError: some View {
        if store.reading.isReading {
            emptyState(title: "Reading the key…", message: nil)
        } else if let message = store.reading.infoError {
            emptyState(title: "The key could not be read", message: message.fullText())
        } else {
            emptyState(title: "Nothing read yet", message: "Press ⌘R to read the key.")
        }
    }

    private func emptyState(title: String, message: String?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
