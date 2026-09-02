import SwiftUI
import FidoPassCore

/// An account's identity as a person can compare it: the hex, and a strip of twelve colours
/// under it. Used by the panel and the manager alike.
///
/// Two sizes. The swatch (`.swatch`) is a small capsule that sits in a list row beside the
/// name and keeps the hex in its tooltip — enough to see that two rows are, or are not, the
/// same account. The full form shows the hex above a wider strip, for the screens where the
/// identity is read out, typed in or checked against paper.
struct IdentityFingerprintView: View {
    enum Style {
        /// Inline in a row: 12 cells of 4 pt, 6 pt tall, no hex.
        case swatch
        /// Hex above a strip, capped in width so it does not become a banner.
        case full
    }

    let identity: AccountIdentity
    var style: Style = .full

    var body: some View {
        switch style {
        case .swatch:
            strip
                .frame(width: CGFloat(IdentityPalette.cellCount) * 4, height: 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Identity \(identity.groupedHex)")
        case .full:
            VStack(alignment: .leading, spacing: 3) {
                Text(identity.groupedHex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                strip
                    .frame(maxWidth: 240)
                    .frame(height: 5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Identity \(identity.groupedHex)")
        }
    }

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(Array(IdentityPalette.colors(for: identity).enumerated()), id: \.offset) { _, color in
                Rectangle().fill(color)
            }
        }
        .clipShape(Capsule())
        // A hairline so the lightest cells do not vanish against a light background.
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .help("Identity \(identity.groupedHex)")
    }
}
