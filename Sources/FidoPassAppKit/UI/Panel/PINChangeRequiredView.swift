import SwiftUI
import FidoPassCore

/// The key refuses everything until its PIN is changed.
///
/// A signpost rather than a form: changing the PIN lives in the manager window now, and this
/// screen exists only because the panel must not leave the user staring at a key that rejects
/// every operation with no way to reach the one thing that fixes it.
struct PINChangeRequiredView: View {
    @ObservedObject var store: HUDStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "A new PIN is required", subtitle: store.selectedDevice?.displayName) {}

            VStack(alignment: .leading, spacing: 10) {
                HUDWarningBox(title: "This key requires a new PIN",
                              message: "It will refuse everything else — including generating passwords — until the PIN is changed. Your passwords will not change: the PIN opens the key, it is not part of how they are derived.")

                HStack {
                    Spacer()
                    Button("Change PIN…") { store.openManager() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
    }
}
