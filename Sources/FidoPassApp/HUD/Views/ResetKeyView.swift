import SwiftUI
import FidoPassCore

/// Erasing the key.
///
/// The most destructive thing the app can do, and the only one whose shape is dictated by the
/// hardware: most authenticators accept a reset only within a few seconds of being plugged in,
/// so the physical reconnect is a step of the wizard rather than an inconvenience.
struct ResetKeyView: View {
    @ObservedObject var store: HUDStore
    let flow: HUDStore.ResetFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No back arrow once the key is being erased: there is nothing to go back to, and
            // an arrow that does nothing reads as a frozen screen.
            HUDScreenHeader(title: "Reset key",
                            subtitle: flow.stage == .confirm ? nil : flow.deviceName,
                            onBack: flow.stage == .running ? nil : { store.cancelReset() })

            VStack(alignment: .leading, spacing: 10) {
                switch flow.stage {
                case .confirm:
                    confirmStage
                case .unplug:
                    instruction(icon: "cable.connector.slash",
                                title: "Unplug the key",
                                detail: "Take it out of the port. Nothing has been erased yet.")
                case .replug:
                    instruction(icon: "cable.connector",
                                title: "Plug the key back in",
                                detail: "The reset starts by itself the moment it is connected — the key only accepts one in the first seconds after power-up.")
                case .running:
                    instruction(icon: "hourglass",
                                title: "Erasing the key",
                                detail: "Touch it when it blinks.")
                }
            }
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Confirmation

    private var confirmStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HUDWarningBox(title: "Everything on this key is erased",
                          message: "Its PIN and every credential go. This is also the only way to revive a key locked by too many wrong PINs.",
                          tint: .red)

            doomedSection

            if flow.requiresTypedConfirmation {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Type RESET to confirm", text: Binding(get: { flow.typed },
                                                                     set: { store.resetFlow?.typed = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Text("A checkbox is not enough here: this key holds an account whose passwords nothing can bring back.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { store.cancelReset() }
                    .keyboardShortcut(.cancelAction)
                Button("Reset key") { store.armReset() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!flow.canProceed)
            }
        }
    }

    @ViewBuilder
    private var doomedSection: some View {
        if !flow.accountsReadable {
            VStack(alignment: .leading, spacing: 3) {
                sectionTitle("What is on this key cannot be listed")
                Text("The key is locked, so its accounts cannot be read. Whatever is on it will be erased.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if flow.doomed.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                sectionTitle("Nothing will be lost")
                Text("There are no accounts on this key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(flow.doomed.count == 1 ? "This account will be erased"
                                                    : "These accounts will be erased")
                ForEach(flow.doomed) { account in
                    doomedRow(account)
                }
                Toggle(isOn: Binding(get: { flow.acknowledged },
                                     set: { store.resetFlow?.acknowledged = $0 })) {
                    Text(flow.doomed.count == 1 ? "I understand this account will be gone"
                                                : "I understand these accounts will be gone")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
            }
        }
    }

    /// One account, as a card: what it is called, what kind it is, and what losing it means.
    ///
    /// The two ways out of a portable account live inside its own card rather than under the
    /// list — with more than one account, buttons floating below would act on whichever
    /// account the app happened to have selected, which is not the one being read about.
    private func doomedRow(_ account: HUDStore.ResetFlow.Doomed) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(account.id)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(account.kind == .portable ? "Portable" : "Local")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(badgeTint(account).opacity(0.16),
                                in: Capsule())
                    .foregroundStyle(badgeTint(account))
            }

            Text(account.kind == .portable
                 ? "Recoverable only from its backup key — and only if you already have it."
                 : "Cannot be recovered by any means once this key is erased.")
                .font(.caption2)
                .foregroundStyle(account.kind == .portable ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            if account.kind == .portable {
                // The last moment either of these can be obtained. Anywhere else means
                // remembering to fetch them before starting, which nobody does.
                HStack(spacing: 6) {
                    Button("Backup key…") { Task { await store.showBackupKey(for: account.ref) } }
                    Button("Recovery sheet…") { store.saveRecoverySheet(for: account.ref) }
                }
                .controlSize(.small)
                .padding(.top, 1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func badgeTint(_ account: HUDStore.ResetFlow.Doomed) -> Color {
        account.kind == .portable ? .secondary : .red
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Waiting on hardware

    private func instruction(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if flow.stage != .running {
                Button("Cancel") { store.cancelReset() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
