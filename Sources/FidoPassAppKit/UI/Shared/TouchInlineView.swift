import SwiftUI

/// The key is waiting for a finger — as one strip, for windows that have content to keep on
/// screen while it waits.
///
/// The panel's `TouchOverlayView` takes the whole panel over, which is right for a 340-point
/// popover with nothing else to show. A window with a message in it must not lose that
/// message to the prompt: this sits in the row the button was in and says the same thing.
struct TouchInlineView: View {
    let prompt: TouchPrompt
    let onCancel: () -> Void

    @State private var pulsing = false
    @State private var elapsed: TimeInterval = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.radiowaves.forward.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .scaleEffect(pulsing ? 1.15 : 0.9)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            VStack(alignment: .leading, spacing: 1) {
                Text(prompt.title).font(.system(size: 12, weight: .semibold))
                Text(elapsed >= 5 ? "\(prompt.message) Press the blinking key." : prompt.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5))
        .onAppear { pulsing = true }
        .onReceive(ticker) { _ in elapsed = Date().timeIntervalSince(prompt.startedAt) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(prompt.title). \(prompt.message)")
    }
}
