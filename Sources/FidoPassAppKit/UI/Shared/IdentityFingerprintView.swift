import SwiftUI
import FidoPassCore

/// Identity hex and sixteen colour cells. Swatches show hex in a tooltip; full views
/// show both for comparison with another key or a recovery sheet.
struct IdentityFingerprintView: View {
    enum Style {
        /// Inline in a row: 16 cells of 3 pt, 6 pt tall, no hex.
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
                .frame(width: CGFloat(IdentityPalette.cellCount) * 3, height: 6)
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
