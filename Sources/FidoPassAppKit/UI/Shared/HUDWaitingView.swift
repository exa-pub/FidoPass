import SwiftUI
import AppKit

/// The app is busy and the key needs no finger — PIN verification, mostly.
///
/// Without it the PIN screen simply stayed on screen while the key was being asked, which
/// reads as "nothing happened, type it again" — and typing it again is how PIN attempts get
/// spent.
struct HUDWaitingView: View {
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, HUDMetrics.padding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
