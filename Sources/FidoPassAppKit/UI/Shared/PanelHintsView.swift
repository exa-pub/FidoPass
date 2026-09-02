import SwiftUI
import AppKit

/// What the keyboard does on this screen.
///
/// Printed rather than left to be discovered: nothing about "Return copies the password"
/// can be guessed from looking at the panel, and an unknown shortcut is no shortcut.
struct PanelHintsView: View {
    let hints: [String]

    var body: some View {
        if !hints.isEmpty {
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
            .accessibilityHidden(true)
        }
    }
}
