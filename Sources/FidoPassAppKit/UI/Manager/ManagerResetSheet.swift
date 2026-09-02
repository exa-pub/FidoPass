import SwiftUI
import FidoPassCore

/// Erasing the key.
///
/// A wizard because the key imposes the steps: most authenticators accept a reset only within
/// seconds of being plugged in, so a physical reconnect is part of the flow rather than a
/// nicety. The staging logic lives in `HUDStore`, which is what coordinates the device, the
/// accounts and the label histories that all die with the key; this only draws it.
struct ManagerResetSheet: View {
    @ObservedObject var store: HUDStore
    let onClose: () -> Void

    /// Seconds the key has been waiting for its touch.
    ///
    /// Without it the wizard sits on one sentence for half a minute, which reads as a hang —
    /// and the usual way a reset fails is precisely that nobody touched the key in time. A
    /// number that moves is the difference between "waiting for you" and "stuck".
    @State private var waited = 0
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Read from the store on every draw rather than taken as a parameter.
    ///
    /// It used to be passed in as a snapshot, and a sheet's content closure is not
    /// re-evaluated by its parent the way an ordinary child view is — so the wizard kept
    /// drawing the stage it was opened with while the flow moved on beneath it. The key
    /// would be blinking for its touch under a sheet still saying "plug it back in".
    private var flow: HUDStore.ResetFlow? { store.resetFlow }

    var body: some View {
        if let flow { content(flow) } else { finished }
    }

    /// The flow is over — the key was erased, or someone cancelled it elsewhere.
    private var finished: some View {
        VStack(spacing: 8) {
            Text("Done").font(.system(size: 13, weight: .semibold))
            ProgressView().controlSize(.small)
        }
        .padding(30)
        .frame(width: 300)
        .onAppear(perform: onClose)
    }

    private func content(_ flow: HUDStore.ResetFlow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reset \(flow.deviceName)").font(.system(size: 15, weight: .semibold))

            switch flow.stage {
            case .confirm: confirmStage(flow)
            case .unplug: waitStage(title: "Unplug the key",
                                    message: "The reset has to be issued within seconds of the key being powered up, so it must be reconnected first.")
            case .replug: waitStage(title: "Plug the key back in",
                                    message: "The reset fires the moment it reappears, and then asks to be touched.")
            case .running:
                waitStage(title: "Touch the key now",
                          message: waited >= 25
                              ? "The key is about to give up. If it has stopped blinking, cancel and start again."
                              : "It is blinking and waiting for a finger — about \(max(0, 30 - waited)) seconds left.")
            }

            if let error = store.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if flow.stage != .running {
                    Button("Cancel") {
                        store.cancelReset()
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if flow.stage == .confirm {
                    Button("Erase the key") { store.armReset() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!flow.canProceed)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onReceive(ticker) { _ in
            guard flow.stage == .running else { waited = 0; return }
            waited += 1
        }
    }

    @ViewBuilder
    private func confirmStage(_ flow: HUDStore.ResetFlow) -> some View {
        Label("This erases every credential on the key and its PIN. There is no way back.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

        if flow.doomed.isEmpty {
            Text(flow.accountsReadable
                 ? "No FidoPass accounts on this key. Its PIN will still be cleared."
                 : "The key is locked, so what it holds could not be read. Anything on it will still be erased.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("These accounts will be destroyed:").font(.caption).foregroundStyle(.secondary)
                ForEach(flow.doomed) { doomed in
                    Text("• \(doomed.ref.accountId) — \(doomed.kind == .portable ? "portable, recoverable from its backup key" : "local, unrecoverable")")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        // Shown only when it actually gates the button. On a key that is known to hold
        // nothing there is nothing to acknowledge, and a checkbox that changes nothing is
        // worse than no checkbox — which is exactly how it read.
        if !flow.isKnownEmpty {
            Toggle("I understand that this cannot be undone",
                   isOn: Binding(get: { store.resetFlow?.acknowledged ?? false },
                                 set: { store.resetFlow?.acknowledged = $0 }))
                .font(.caption)
        }

        // A local account's passwords cannot be recovered by any means, so erasing one asks
        // for more than a click.
        if flow.requiresTypedConfirmation {
            VStack(alignment: .leading, spacing: 4) {
                Text("Type RESET to confirm").font(.caption).foregroundStyle(.secondary)
                TextField("", text: Binding(get: { store.resetFlow?.typed ?? "" },
                                            set: { store.resetFlow?.typed = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func waitStage(title: String, message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
