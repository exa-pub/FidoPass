import SwiftUI
import FidoPassCore

/// One label/value line. Values are selectable: half the point of this window is being able
/// to take an id out of it and paste it somewhere else.
struct ManagerRow: View {
    let label: String
    let value: String
    var monospaced = false
    var copyable = false

    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 190, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button(copied ? "Copied" : "Copy") {
                    // Not a secret, but it identifies its owner at some relying party — so it
                    // goes through the concealed path like everything else, and is not synced
                    // to other devices. No timeout: it exists to be pasted.
                    _ = ClipboardService.copySecret(value, clearAfter: 0)
                    copied = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
