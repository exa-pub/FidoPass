import SwiftUI
import FidoPassCore

struct NoKeyView: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void

    /// Re-checks while this screen is on display. A key that is re-enumerating after a touch
    /// comes back within a second or two, and waiting for the user to discover a button
    /// would make a blip look like a dead application.
    private let retry = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No security key connected")
                .font(.system(size: 13, weight: .semibold))
            Text("FidoPass keeps nothing on this Mac — the accounts live on the key, and a password exists only while it is on screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Look again")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .onReceive(retry) { _ in if !isRefreshing { onRefresh() } }
    }
}
