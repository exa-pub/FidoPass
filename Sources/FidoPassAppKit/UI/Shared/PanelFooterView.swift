import SwiftUI
import AppKit

/// One line of feedback under the content: what just happened, or what went wrong.
///
/// Takes the same height as `PanelHintsView`, which it replaces for a few seconds: the
/// panel must not resize when the status expires. A message long enough to wrap still
/// grows the strip — that beats truncating it.
struct PanelFooterView: View {
    let status: String?
    let error: PresentedError?
    /// PIN attempts left, for a wrong-PIN failure to say how many remain.
    var retriesRemaining: Int? = nil

    var body: some View {
        if let error {
            label(error.fullText(retriesRemaining: retriesRemaining), icon: "exclamationmark.triangle.fill", tint: .orange)
        } else if let status {
            label(status, icon: "checkmark.circle.fill", tint: .green)
        }
    }

    private func label(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: PanelMetrics.footerHeight)
        .background(.quaternary.opacity(0.4))
    }
}
