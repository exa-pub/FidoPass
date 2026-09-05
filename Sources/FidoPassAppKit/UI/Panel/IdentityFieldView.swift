import SwiftUI
import FidoPassCore

/// Editable identity for creation/migration, or a read-only identity when resuming a copy.
struct IdentityFieldView: View {
    @Binding var hex: String
    let identity: AccountIdentity?
    let error: String?
    var isEditable = true
    var onRandomise: () -> Void
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("Identity, 32 hex characters", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(!isEditable)
                    .onSubmit(onSubmit)
                if isEditable {
                    Button(action: onRandomise) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Pick a random identity")
                }
            }

            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            } else if let identity {
                IdentityFingerprintView(identity: identity)
            }
        }
    }
}
