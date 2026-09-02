import SwiftUI
import AppKit

/// One line of feedback under the content: what just happened, or what went wrong.
struct HUDFooterView: View {
    let status: String?
    let error: String?

    var body: some View {
        if let error {
            label(error, icon: "exclamationmark.triangle.fill", tint: .orange)
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
        .padding(.horizontal, HUDMetrics.padding)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }
}
