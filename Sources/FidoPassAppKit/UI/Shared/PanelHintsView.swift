import SwiftUI
import AppKit

/// What the keyboard does on this screen.
///
/// Printed rather than left to be discovered: nothing about "Return copies the password"
/// can be guessed from looking at the panel, and an unknown shortcut is no shortcut.
///
/// The strip keeps its height when there is nothing to print: it is the same slot a status
/// or an error takes over, and the panel's height must not depend on which of the three is
/// showing — see `PanelMetrics.footerHeight`.
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
