import SwiftUI
import FidoPassCore

/// An account's identity as a person can compare it: the hex, and a strip of twelve colours
/// under it. Used by the panel and the manager alike.
///
/// The strip is the quick look — "these two rows are the same account" — and the hex is
/// what gets read out or typed. List rows show only the strip and keep the hex in the
/// tooltip; screens where the hex is compared or entered show both.
struct IdentityFingerprintView: View {
    let identity: AccountIdentity
    /// The hex above the strip. List rows pass `false` and rely on the tooltip.
    var showsHex = true
    var height: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsHex {
                Text(identity.groupedHex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            strip
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Identity \(identity.groupedHex)")
    }

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(Array(IdentityPalette.colors(for: identity).enumerated()), id: \.offset) { _, color in
                Rectangle().fill(color)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(Capsule())
        // A hairline so the lightest cells do not vanish against a light background.
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .help("Identity \(identity.groupedHex)")
    }
}
