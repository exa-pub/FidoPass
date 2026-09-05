import SwiftUI
import FidoPassCore

/// Manager inventory and settings, including all relying parties.
/// Core redacts portable key material before presentation or export.
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
            } else if store.device == nil {
                emptyState(title: "Choose a key", message: "The previous connection is no longer available.")
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
        .onChange(of: store.isUnlocked) { _, unlocked in
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
            // The same explicit read is available from the keyboard on every tab.
            Button("") { Task { await store.read() } }
                .keyboardShortcut("r", modifiers: [.command])
                .opacity(0)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if !devices.devices.isEmpty {
                    Picker("Key", selection: Binding(get: { store.device?.path ?? "" }, set: { path in Task { await store.selectDevice(path: path) } })) {
                        if store.device == nil { Text("Choose a key…").tag("") }
                        ForEach(devices.devices) { candidate in
                            Text(candidate.displayName).tag(candidate.path)
                        }
                    }
                    .disabled(store.hasPendingForm)
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
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if touchGate.isCancelling, touchGate.surface == .manager {
                Label("Finishing cancelled operation…", systemImage: "hourglass").font(.caption)
            }
            if !store.isUnlocked, store.device != nil {
                HStack(spacing: 6) {
                    Label(store.keyState?.hasPIN == false ? "PIN not set" : "Key locked", systemImage: "lock").font(.caption)
                    Text("— credentials cannot be listed until it is.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(store.keyState?.hasPIN == false ? "Set PIN…" : "Unlock…") { store.requestUnlock() }
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
        let path = store.device?.path
        switch store.tab {
        case .overview:
            if let info = reading.info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        AuthenticatorOverviewView(info: info, inventory: reading.inventory)
                        HStack {
                            Button(store.keyState?.hasPIN == false ? "Set PIN…" : "Open accounts…") { store.requestUnlock() }
                            Button("Read key") { Task { await store.read() } }
                            Button("Key settings") { store.tab = .settings }
                        }.disabled(touchGate.isWorking)
                    }
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
                        deviceName: store.device?.displayName ?? "Key",
                        hasDraft: $store.hasSettingsDraft,
                        isUnlocked: store.isUnlocked,
                        onUnlock: { store.requestUnlock() },
                        onToggleAlwaysUV: { Task { await store.toggleAlwaysUV(expectedPath: path) } },
                        onRaiseMinimumPIN: { length in Task { await store.raiseMinimumPIN(to: length, expectedPath: path) } },
                        onForcePINChange: { Task { await store.forcePINChange(expectedPath: path) } },
                        onEnableEnterpriseAttestation: { Task { await store.enableEnterpriseAttestation(expectedPath: path) } },
                        onChangePIN: { store.beginChangePIN() },
                        onReset: { Task { await store.beginReset() } },
                        isBusy: store.isApplying || reading.isReading,
                        errorText: store.settingsError?.fullText())
                    .id(path)
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
            emptyState(title: "The key could not be read", message: message.fullText(), canRead: true)
        } else {
            emptyState(title: "Nothing read yet", message: "Read the selected key to see its current contents.", canRead: true)
        }
    }

    private func emptyState(title: String, message: String?, canRead: Bool = false) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if canRead {
                Button("Read key") { Task { await store.read() } }
                    .disabled(touchGate.isWorking || store.isResetting)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
