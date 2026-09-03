import SwiftUI

/// The eye that shows or hides a pane of secret text, for the pane's header row.
struct RevealToggle: View {
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isRevealed ? "Hide the text" : "Show the text")
        .accessibilityLabel(isRevealed ? "Hide the text" : "Show the text")
    }
}
