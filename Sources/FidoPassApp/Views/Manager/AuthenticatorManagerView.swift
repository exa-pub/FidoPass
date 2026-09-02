import SwiftUI
import FidoPassCore
#if canImport(AppKit)
import AppKit
#endif

/// The FIDO manager window: what is on the key, as the key describes it.
///
/// Deliberately without product framing. Relying parties are shown as they are — FidoPass's
/// own two sit in the same list as `github.com` — because the window's purpose is to show
/// the authenticator, not the app's view of it. The one exception is FidoPass portable key
/// material, which is withheld in the core; see `CredentialUserName`.
///
/// **Opening this window is the request to read.** Opening a key on macOS seizes it away
/// from every other process, so the app must never do it merely because a key appeared — but
/// choosing this window from a menu is as explicit as pressing a button inside it, and a
/// window whose every page said "press Read first" was asking twice for the same thing.
struct AuthenticatorManagerView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject private var devices: DeviceStore
    @ObservedObject private var inventory: InventoryStore

    @State private var tab: ManagerTab = .credentials
    @State private var selectedCredential: String?
    @State private var settingsError: String?
    @State private var isApplyingSetting = false
    @State private var chosenPath: String?
    @State private var sheet: KeySheet?

    init(store: HUDStore) {
        self.store = store
        self.devices = store.devices
        self.inventory = store.inventory
    }

    private enum KeySheet: String, Identifiable {
        case changePIN, reset
        var id: String { rawValue }
    }

    private var device: FidoDevice? {
        if let chosenPath, let match = devices.devices.first(where: { $0.path == chosenPath }) { return match }
        return devices.devices.first
    }

    private var reading: InventoryStore.Reading {
        guard let device else { return InventoryStore.Reading() }
        return inventory.reading(for: device.path)
    }

    /// True from the moment the wizard opens until the key is erased or the flow cancelled.
    private var isResetting: Bool { store.resetFlow != nil || devices.armedReset != nil }

    private var isUnlocked: Bool {
        guard let device else { return false }
        return devices.state(for: device.path)?.unlocked == true
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
        // Opening the window is the request. Keyed on the device so switching keys reads the
        // one now on screen rather than leaving the other one's answers up.
        .task(id: device?.path) {
            guard let device, !inventory.reading(for: device.path).hasAnything else { return }
            // A reset makes the key reappear on a new path, which is exactly what re-triggers
            // this. Reading it then would seize the device in the seconds-wide window where
            // the reset has to be issued — and there is nothing worth reading off a key that
            // is about to be erased.
            guard !isResetting else { return }
            await inventory.read(device)
        }
        // Unlocking completes a read that stopped for want of a PIN. A key nobody asked
        // about is left alone — `InventoryStore.resumeAfterUnlock` checks.
        .onChange(of: isUnlocked) { unlocked in
            guard unlocked, let device else { return }
            Task { await inventory.resumeAfterUnlock(device) }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .changePIN:
                ManagerChangePINSheet(store: store, devices: devices) { sheet = nil }
            case .reset:
                ManagerResetSheet(store: store) { sheet = nil }
            }
        }
        .background {
            // No button for it: re-reading is rare, and a row of buttons was noise on a
            // window whose whole job is to be read.
            Button("") {
                guard let device else { return }
                Task { await inventory.read(device) }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .opacity(0)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if devices.devices.count > 1 {
                    Picker("", selection: Binding(get: { device?.path ?? "" }, set: { chosenPath = $0 })) {
                        ForEach(devices.devices) { candidate in
                            Text(candidate.displayName).tag(candidate.path)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                } else if let device {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.displayName).font(.system(size: 13, weight: .semibold))
                        Text(device.identityLabel).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if reading.isReading || isApplyingSetting {
                    ProgressView().controlSize(.small)
                }
            }

            // Only the locked state earns a line. Unlocked is the ordinary case, and a badge
            // that is almost always present is a badge nobody reads.
            if !isUnlocked, !devices.devices.isEmpty {
                HStack(spacing: 6) {
                    Label("Key locked", systemImage: "lock").font(.caption)
                    Text("— credentials cannot be listed until it is.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Unlock…") {
                        guard let device else { return }
                        store.requestUnlock(devicePath: device.path)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if let message = reading.infoError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $tab) {
            ForEach(ManagerTab.allCases) { candidate in
                HStack {
                    Label(candidate.title, systemImage: candidate.symbol)
                    Spacer(minLength: 4)
                    if candidate == .credentials, let count = reading.inventory?.credentialCount {
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
        switch tab {
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
                CredentialsBrowserView(inventory: inventory, selection: $selectedCredential)
            } else if let message = reading.inventoryError {
                emptyState(title: "The credentials could not be read", message: message)
            } else if reading.needsUnlock {
                emptyState(title: "The key is locked", message: "Unlock it to list the credentials it holds.")
            } else {
                readingOrError
            }

        case .settings:
            if let info = reading.info, let device {
                ScrollView {
                    AuthenticatorSettingsView(
                        info: info,
                        isUnlocked: isUnlocked,
                        onUnlock: { store.requestUnlock(devicePath: device.path) },
                        onToggleAlwaysUV: { apply { try await devices.toggleAlwaysUV(for: device) } },
                        onRaiseMinimumPIN: { length in
                            apply { try await devices.setMinimumPINLength(for: device, length: length) }
                        },
                        onForcePINChange: { apply { try await devices.forcePINChange(for: device) } },
                        onEnableEnterpriseAttestation: {
                            apply { try await devices.enableEnterpriseAttestation(for: device) }
                        },
                        onChangePIN: {
                            store.errorText = nil
                            store.pinForm.clear()
                            sheet = .changePIN
                        },
                        onReset: {
                            store.errorText = nil
                            Task {
                                await store.beginReset()
                                // `beginReset` refuses with more than one key connected, and
                                // says why in `errorText`. No sheet in that case.
                                if store.resetFlow != nil { sheet = .reset }
                            }
                        },
                        isBusy: isApplyingSetting || reading.isReading,
                        errorText: settingsError)
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
        if reading.isReading {
            emptyState(title: "Reading the key…", message: nil)
        } else if let message = reading.infoError {
            emptyState(title: "The key could not be read", message: message)
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

    // MARK: - Settings

    /// Runs one setting change and then re-reads the key.
    ///
    /// The re-read is not optional: `alwaysUv` is a *toggle*, so the resulting state is
    /// whatever the key now says rather than what the switch was moved to, and a control
    /// showing the app's guess instead of the key's answer is how a setting silently reads
    /// backwards.
    private func apply(_ operation: @escaping () async throws -> Void) {
        guard let device, !isApplyingSetting else { return }
        settingsError = nil
        isApplyingSetting = true
        Task {
            do {
                try await operation()
            } catch {
                settingsError = FidoPassErrorPresenter.message(for: error).fullText()
            }
            await inventory.refreshInfo(device)
            isApplyingSetting = false
        }
    }
}
