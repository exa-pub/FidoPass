import SwiftUI
import FidoPassCore

/// Controls only advertised authenticator settings. Minimum PIN length and enterprise
/// attestation require confirmation because reset is needed to undo them.
struct AuthenticatorSettingsView: View {
    let info: AuthenticatorInfo
    let deviceName: String
    @Binding var hasDraft: Bool
    let isUnlocked: Bool
    let onUnlock: () -> Void
    let onToggleAlwaysUV: () -> Void
    let onRaiseMinimumPIN: (Int) -> Void
    let onForcePINChange: () -> Void
    let onEnableEnterpriseAttestation: () -> Void
    let onChangePIN: () -> Void
    let onReset: () -> Void
    let isBusy: Bool
    let errorText: String?

    @State private var pendingMinimum: Int = 0
    @State private var isRaising = false
    @State private var confirming: Confirmation?

    private enum Confirmation: Identifiable {
        case minimumPIN(Int)
        case forcePINChange
        case enterpriseAttestation
        var id: String {
            switch self {
            case .minimumPIN(let value): return "min-\(value)"
            case .forcePINChange: return "force"
            case .enterpriseAttestation: return "ep"
            }
        }
    }

    private var currentMinimum: Int { info.minPINLength ?? PinPolicy.ctapFloor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ManagerSectionHeader(title: "Settings — \(deviceName)",
                                 note: "What this authenticator will let you change about itself. Each needs the PIN; none needs a touch.")

            if !info.supportsConfiguration {
                Label("This key does not implement authenticator configuration, so nothing here can be changed.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                configurable
            }
            keyOperations
        }
        .disabled(isBusy)
        .onAppear { pendingMinimum = max(currentMinimum + 1, PinPolicy.ctapFloor + 1) }
        .onChange(of: isRaising) { updateDraftState() }
        .onChange(of: confirming?.id) { updateDraftState() }
        .onDisappear { hasDraft = false }
        .alert(item: $confirming) { confirmation in confirmationAlert(confirmation) }
    }

    @ViewBuilder
    private var configurable: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isUnlocked {
                HStack(spacing: 6) {
                    Label("The key must be unlocked to change anything.", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Unlock…", action: onUnlock).buttonStyle(.link).font(.caption)
                }
                .padding(.bottom, 12)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }

            alwaysUV
            minimumPIN
            forcePIN
            enterpriseAttestation
        }
    }

    /// PIN and reset. Deliberately outside `configurable`: neither needs `authnrCfg`, and
    /// neither needs the key to be unlocked — a PIN change proves knowledge of the old PIN,
    /// and a reset is precisely what a key nobody can open is for.
    @ViewBuilder
    private var keyOperations: some View {
        Text("PIN")
            .font(.caption).foregroundStyle(.tertiary).textCase(.uppercase)
            .padding(.top, 18).padding(.bottom, 2)

        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Change the key's PIN").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 12)
                Button("Change PIN…", action: onChangePIN).font(.caption)
            }
            Text("Works on a locked key: proving the old PIN is the same proof unlocking asks for. Your passwords are unaffected — the PIN opens the key, it is not part of how passwords are derived.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        Divider()

        Text("Danger zone")
            .font(.caption).foregroundStyle(.tertiary).textCase(.uppercase)
            .padding(.top, 18).padding(.bottom, 2)

        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reset the key").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 12)
                Button("Reset…", action: onReset).font(.caption).foregroundStyle(.red)
            }
            Text("Erases every credential on the key and its PIN. A local account's passwords cannot be recovered by any means afterwards. The key must be unplugged and reconnected as part of the flow, because most authenticators only accept a reset in the first seconds after power-up.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Settings

    @ViewBuilder
    private var alwaysUV: some View {
        setting(title: "Always require user verification",
                explanation: "With this on the key asks for its PIN on every operation, even ones a website said could be done without it. FidoPass already requires the PIN, so this mainly affects other software using the same key. Reversible.",
                supported: info.canToggleAlwaysUV,
                unsupportedNote: "This key does not offer the alwaysUv option.") {
            Toggle("", isOn: Binding(get: { info.alwaysUV }, set: { _ in onToggleAlwaysUV() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!isUnlocked)
        }
    }

    /// Shows the current minimum separately; CTAP only permits increases without reset.
    @ViewBuilder
    private var minimumPIN: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Minimum PIN length").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 12)
                if info.canSetMinimumPINLength {
                    Text("\(currentMinimum)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("unsupported").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if info.canSetMinimumPINLength {
                Text("Can only be raised. There is no command in CTAP to lower it, so no software can undo this — only a full reset of the key, which erases every credential on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isRaising {
                    HStack(spacing: 8) {
                        Text("Raise to").font(.caption)
                        Stepper(value: $pendingMinimum, in: (currentMinimum + 1)...63) {
                            Text("\(pendingMinimum)").font(.system(size: 12, design: .monospaced))
                        }
                        .frame(width: 90)
                        Button("Raise…") { confirming = .minimumPIN(pendingMinimum) }
                            .font(.caption)
                            .disabled(!isUnlocked)
                        Button("Cancel") { isRaising = false }
                            .buttonStyle(.link)
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                } else {
                    Button("Raise…") {
                        pendingMinimum = max(currentMinimum + 1, PinPolicy.ctapFloor + 1)
                        isRaising = true
                    }
                    .font(.caption)
                    .disabled(!isUnlocked)
                    .padding(.top, 2)
                }
            } else {
                Text("This key does not support setting a minimum PIN length.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .opacity(info.canSetMinimumPINLength ? 1 : 0.55)
        Divider()
    }

    @ViewBuilder
    private var forcePIN: some View {
        setting(title: "Force a PIN change",
                explanation: "The key will refuse every operation until a new PIN is set. Undone only by actually changing the PIN.",
                supported: info.canForcePINChange,
                unsupportedNote: "This key has no PIN to change yet.") {
            Button("Require…") { confirming = .forcePINChange }
                .font(.caption)
                .disabled(!isUnlocked || info.forcePINChange)
        }
    }

    @ViewBuilder
    private var enterpriseAttestation: some View {
        if info.canEnableEnterpriseAttestation {
            setting(title: "Enterprise attestation",
                    explanation: "Lets the key identify itself individually to relying parties that ask for it — the opposite of the privacy property an AAGUID normally provides. **This cannot be undone.**",
                    supported: true,
                    unsupportedNote: "") {
                if info.enterpriseAttestationEnabled {
                    Text("enabled").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Enable…") { confirming = .enterpriseAttestation }
                        .font(.caption)
                        .disabled(!isUnlocked)
                }
            }
        }
    }

    // MARK: - Plumbing

    @ViewBuilder
    private func setting<Control: View>(title: String,
                                        explanation: String,
                                        supported: Bool,
                                        unsupportedNote: String,
                                        @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 12)
                if supported {
                    control()
                } else {
                    Text("unsupported").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(.init(supported ? explanation : unsupportedNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .opacity(supported ? 1 : 0.55)
        Divider()
    }

    private func updateDraftState() { hasDraft = isRaising || confirming != nil }

    private func confirmationAlert(_ confirmation: Confirmation) -> Alert {
        switch confirmation {
        case .minimumPIN(let value):
            return Alert(title: Text("Raise minimum PIN to \(value) on \(deviceName)?"),
                         message: Text("This cannot be undone. The minimum can never be lowered again, on this key, by any software. If your current PIN is shorter than \(value) the key will demand a new one before it does anything else."),
                         primaryButton: .destructive(Text("Raise")) { onRaiseMinimumPIN(value) },
                         secondaryButton: .cancel())
        case .forcePINChange:
            return Alert(title: Text("Require a new PIN on \(deviceName)?"),
                         message: Text("The key will refuse every operation — including generating passwords — until you set a new PIN."),
                         primaryButton: .destructive(Text("Require")) { onForcePINChange() },
                         secondaryButton: .cancel())
        case .enterpriseAttestation:
            return Alert(title: Text("Enable enterprise attestation on \(deviceName)?"),
                         message: Text("This cannot be undone. The key will be able to identify itself individually to relying parties that request it."),
                         primaryButton: .destructive(Text("Enable")) { onEnableEnterpriseAttestation() },
                         secondaryButton: .cancel())
        }
    }
}
