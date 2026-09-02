import SwiftUI
import AppKit

/// The key is waiting for a finger.
///
/// Rendered inside the panel rather than as a floating window: the operation belongs to
/// what the user just clicked, and a separate window would need its own focus handling for
/// no gain.
struct TouchOverlayView: View {
    let prompt: TouchPrompt
    let onCancel: () -> Void

    @State private var pulsing = false
    @State private var elapsed: TimeInterval = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 54, height: 54)
                    .scaleEffect(pulsing ? 1.12 : 0.94)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }
            Text(prompt.title)
                .font(.headline)
            Text(prompt.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(prompt.deviceName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if elapsed >= 5 {
                // Some keys give no visible sign that they are waiting.
                Text("Press the blinking key.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, HUDMetrics.padding)
        .onAppear { pulsing = true }
        .onReceive(ticker) { _ in elapsed = Date().timeIntervalSince(prompt.startedAt) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(prompt.title). \(prompt.message)")
    }
}
