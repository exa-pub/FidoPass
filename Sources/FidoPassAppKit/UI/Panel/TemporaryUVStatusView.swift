import SwiftUI

struct TemporaryUVStatusView: View {
    @ObservedObject var store: TemporaryUVStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(store.device?.displayName ?? "Security key")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button("Cancel pause") {
                    Task { await store.restore() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(store.phase != .paused)
                .help("End the pause and restore Require UV now")
            }
            .padding(.horizontal, PanelMetrics.padding)
            .frame(height: 44)
            .background(Color.orange.opacity(0.08))
            .help("The timer runs in FidoPass. Keep the app running and the key connected; restoration is only confirmed after the key accepts it.")
        }
    }

    private var title: String {
        switch store.phase {
        case .idle, .preparing: "Pausing Require UV…"
        case .paused:
            if store.error != nil { "Require UV restoration not confirmed" }
            else if store.remainingSeconds() == 0 { "Waiting to restore Require UV…" }
            else { "Require UV paused · \(countdown)" }
        case .restoring: "Restoring Require UV…"
        }
    }

    private var countdown: String {
        let seconds = store.remainingSeconds()
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
