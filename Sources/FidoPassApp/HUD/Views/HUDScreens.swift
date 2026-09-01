import SwiftUI
import FidoPassCore

/// PIN entry.
///
/// The field takes focus the moment the panel opens, so the whole "wake the HUD, unlock,
/// get the password" path can be typed without touching the mouse.
struct UnlockView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject var devices: DeviceStore
    @FocusState private var pinFocused: Bool
    /// Reading the key's status opens it, and an opened key is seized from every other
    /// process. One read per appearance of this screen, and only once the user has started
    /// typing — see `askForStatus`.
    @State private var statusRequested = false

    private var retries: Int? { devices.selectedState?.pinRetriesRemaining }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let pending = store.pendingSummary {
                Text(pending)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter the key PIN. It is kept in memory for five minutes, then asked again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                SecureField("PIN", text: $store.pinDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($pinFocused)
                    .onSubmit { Task { await store.submitPin() } }
                Button("Unlock") { Task { await store.submitPin() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.pinDraft.isEmpty || store.isWorking)
            }

            if let retries { PinAttemptsLabel(remaining: retries) }
        }
        .padding(.horizontal, HUDMetrics.padding)
        .padding(.vertical, 12)
        .onAppear {
            pinFocused = true
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
        .onChange(of: pinFocused) { focused in
            if focused { KeyboardLayoutService.preferEnglishLayoutIfNeeded() }
        }
        .onChange(of: store.pinDraft) { draft in
            if !draft.isEmpty { askForStatus() }
        }
    }
}

extension UnlockView {
    /// Asks the key how many attempts are left — on the first character typed, not when this
    /// screen appears.
    ///
    /// The screen appears the moment a key is plugged in, and opening a key seizes it
    /// (`libfido2/src/hid_osx.c`, `kIOHIDOptionsTypeSeizeDevice`). That is how a running
    /// FidoPass used to break `ykman fido reset`: the key was taken over within a second of
    /// being connected, before its owner had asked for anything. Typing a PIN is asking; the
    /// key being present is not. By the time a PIN is finished the count is on screen, which
    /// is where it matters — before the attempt is spent.
    fileprivate func askForStatus() {
        guard !statusRequested, let device = store.selectedDevice else { return }
        statusRequested = true
        Task { await devices.refreshStatus(for: device) }
    }
}

/// How many PIN attempts are left before the key locks itself for good.
///
/// Eight consecutive failures are terminal, and nothing recovers from that but a factory
/// reset that wipes every credential — so the countdown is stated plainly rather than left
/// for the user to discover.
struct PinAttemptsLabel: View {
    let remaining: Int

    var body: some View {
        Label(text, systemImage: remaining <= 1 ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.caption)
            .foregroundStyle(color)
    }

    private var text: String {
        switch remaining {
        case 0:  return "Locked — no attempts left"
        case 1:  return "1 attempt left before this key locks permanently"
        default: return "\(remaining) attempts left"
        }
    }

    private var color: Color {
        switch remaining {
        case 0, 1: return .red
        case 2, 3: return .orange
        default:   return .secondary
        }
    }
}

/// Creating an account. Portable is the default because losing the only key that can derive
/// a vault master password is unrecoverable.
struct EnrollView: View {
    @ObservedObject var store: HUDStore
    @FocusState private var idFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "New account", subtitle: store.selectedDevice?.displayName) {
                store.backToAccounts()
            }

            VStack(alignment: .leading, spacing: 9) {
                TextField("Account ID, e.g. vault", text: $store.enrollDraft.accountId)
                    .textFieldStyle(.roundedBorder)
                    .focused($idFocused)
                    .onSubmit { Task { await store.createAccount() } }

                Picker("", selection: $store.enrollDraft.kind) {
                    Text("Portable").tag(AccountKind.portable)
                    Text("Local").tag(AccountKind.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(store.enrollDraft.kind == .portable
                     ? "Can be copied onto a second key, so these passwords survive losing this one. Recommended."
                     : "Bound to this key alone. If it is lost or reset, these passwords cannot be recovered by any means.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.enrollDraft.kind == .portable {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Existing backup key (optional, base64)", text: $store.enrollDraft.importedKeyB64)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        if let error = store.enrollDraft.importedKeyError {
                            Text(error).font(.caption2).foregroundStyle(.red)
                        } else {
                            Text("Leave empty to create a fresh key. Fill it in to make this key derive the same passwords as another one.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let step = store.enrollStep {
                    Label(step, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { store.backToAccounts() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") { Task { await store.createAccount() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.enrollDraft.canCreate || store.isWorking)
                }
            }
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
        .onAppear { idFocused = true }
    }
}

/// The value that reproduces every password of a portable account.
///
/// It gets its own screen, its own wording and no resemblance to a password field: pasting
/// it into a login box would be a catastrophe, and the UI must make that impossible to do
/// by accident.
struct BackupKeyView: View {
    @ObservedObject var store: HUDStore
    let ref: AccountRef
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "Backup key", subtitle: ref.accountId) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 9) {
                HUDWarningBox(title: "This is not a password",
                              message: "Anyone holding this value can reproduce every password of this account without the security key. Store it offline — a safe, a printed copy — and never paste it into a website.")

                Text(revealed ? (store.backupKey ?? "") : String(repeating: "•", count: 32))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("Enter it on a second security key to make that key derive the same passwords.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(revealed ? "Hide" : "Reveal") { revealed.toggle() }
                        .controlSize(.small)
                    Button("Copy") { store.copyBackupKey() }
                        .controlSize(.small)
                    Spacer()
                    Button("Done") { store.backToAccounts() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
    }
}

struct ConfirmDeleteView: View {
    @ObservedObject var store: HUDStore
    let ref: AccountRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "Delete account", subtitle: ref.accountId) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 9) {
                HUDWarningBox(title: "No way back",
                              message: "“\(ref.accountId)” is erased from the key. Every password derived from it becomes unreachable, and a vault master password has no reset.",
                              tint: .red)
                HStack {
                    Spacer()
                    Button("Cancel") { store.backToAccounts() }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete") { Task { await store.deleteAccount(ref) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(store.isWorking)
                }
            }
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
    }
}

/// What the key itself reports. Read without a PIN and without a touch.
struct KeyInfoView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject var devices: DeviceStore
    @State private var status: DeviceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "Key info", subtitle: store.selectedDevice?.displayName) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 7) {
                if let device = store.selectedDevice {
                    row("Identifier", device.identityLabel)
                }
                if let status {
                    row("PIN configured", status.hasPIN ? "yes" : "no — enrolment needs one")
                    row("hmac-secret", status.supportsHmacSecret ? "supported" : "missing — passwords cannot be derived")
                    row("PIN attempts left", status.pinRetriesRemaining.map(String.init) ?? "not reported")
                    row("Shortest PIN allowed", status.minPINLength.map(String.init) ?? "4 (the protocol minimum)")
                    if status.forcePINChange {
                        row("PIN change", "required before anything else")
                    }
                    row("Free credential slots", status.remainingResidentKeys.map(String.init) ?? "not reported")
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Reading…").font(.caption).foregroundStyle(.secondary) }
                }
                if let aaguid = status?.aaguid {
                    row("Model (AAGUID)", String(aaguid.prefix(8)))
                }
                Text("Device paths change on every reconnect, so they are never stored. The AAGUID names the model, not this key — it is shared by every key like it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
        .task {
            guard let device = store.selectedDevice else { return }
            status = await devices.status(for: device)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption).multilineTextAlignment(.trailing)
        }
    }
}
