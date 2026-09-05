import SwiftUI
import AppKit

/// Keyboard hints reserve the same minimum height as status and error messages.
struct PanelHintsView: View {
    let hints: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: PanelMetrics.footerHeight)
        .accessibilityHidden(true)
    }
}
