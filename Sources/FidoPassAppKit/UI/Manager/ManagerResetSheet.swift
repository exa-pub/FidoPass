import SwiftUI
import FidoPassCore

/// Erasing the key.
///
/// A wizard because the key imposes the steps: most authenticators accept a reset only within
/// seconds of being plugged in, so a physical reconnect is part of the flow rather than a
/// nicety. The staging logic lives in `ResetCoordinator`; this only draws it.
struct ManagerResetSheet: View {
    @ObservedObject var store: ManagerStore
    @ObservedObject private var reset: ResetCoordinator
    @ObservedObject private var touchGate: TouchGate

    /// Redrawn once a second while the key waits for its touch.
    ///
    /// Without it the wizard sits on one sentence for half a minute, which reads as a hang —
    /// and the usual way a reset fails is precisely that nobody touched the key in time. A
    /// number that moves is the difference between "waiting for you" and "stuck".
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(store: ManagerStore, touchGate: TouchGate) {
        self.store = store
        self.reset = store.reset
        self.touchGate = touchGate
    }

    /// Seconds the key has been waiting for its touch, from the prompt the gate is showing.
    private var waited: Int {
        guard let prompt = touchGate.managerPrompt else { return 0 }
        return max(0, Int(now.timeIntervalSince(prompt.startedAt)))
    }

    var body: some View {
        Group {
            if let flow = reset.flow { content(flow) } else { finished }
        }
        // The flow ends in the coordinator — the key was erased, or someone cancelled it —
        // and the sheet follows it down rather than lingering on "Done".
        .onChange(of: reset.flow == nil) { over in
            if over { store.resetSheetFinished() }
        }
        .onReceive(ticker) { now = $0 }
    }

    private var finished: some View {
        VStack(spacing: 8) {
            Text("Done").font(.system(size: 13, weight: .semibold))
            ProgressView().controlSize(.small)
        }
        .padding(30)
        .frame(width: 300)
    }

    private func content(_ flow: ResetFlow) -> some View {
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

            if let error = reset.error {
                Text(error.fullText())
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if flow.stage != .running {
                    Button("Cancel") { store.cancelReset() }
                        .keyboardShortcut(.cancelAction)
                }
                if flow.stage == .confirm {
                    Button("Erase the key") { reset.arm() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!flow.canProceed)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private func confirmStage(_ flow: ResetFlow) -> some View {
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
                   isOn: Binding(get: { reset.flow?.acknowledged ?? false },
                                 set: { reset.flow?.acknowledged = $0 }))
                .font(.caption)
        }

        // A local account's passwords cannot be recovered by any means, so erasing one asks
        // for more than a click.
        if flow.requiresTypedConfirmation {
            VStack(alignment: .leading, spacing: 4) {
                Text("Type RESET to confirm").font(.caption).foregroundStyle(.secondary)
                TextField("", text: Binding(get: { reset.flow?.typed ?? "" },
                                            set: { reset.flow?.typed = $0 }))
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
