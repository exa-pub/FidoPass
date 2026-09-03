import SwiftUI
import FidoPassCore

/// An encryption key's fingerprint as a person compares it: six emoji in a capsule, the
/// twelve hex digits beside them. One line — it sits under a text field, not on a poster.
///
/// The emoji are the whole defence against a substituted link — the fragment in the link is
/// a checksum anyone can recompute — so the tooltip says what to do with them; the window
/// says it once more in its footer.
struct KeyFingerprintView: View {
    let fingerprint: MessageKeyFingerprint

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(fingerprint.emojiCharacters.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 14))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            Text(fingerprint.hex)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .help("Key fingerprint — compare the six emoji with the key's owner over another channel before you encrypt.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Key fingerprint \(fingerprint.hex)")
    }
}
