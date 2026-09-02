import SwiftUI
import AppKit

/// A screen title with a way back, used by every pushed screen.
struct PanelScreenHeader: View {
    let title: String
    var subtitle: String?
    /// Omitted when there is nowhere to go back to. A visible arrow that does nothing is
    /// worse than no arrow — it reads as a screen that has stopped responding.
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
