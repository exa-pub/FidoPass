import SwiftUI
import FidoPassCore

/// Six emoji and twelve hex digits for out-of-band comparison with the key owner.
/// The checksum alone does not authenticate the link.
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
