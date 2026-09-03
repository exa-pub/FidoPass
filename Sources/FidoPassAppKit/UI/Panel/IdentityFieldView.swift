import SwiftUI
import FidoPassCore

/// The identity an account is about to be created with: the hex, a button for a fresh
/// random one, and the fingerprint it makes, live.
///
/// Used by the "new account" form and the migration screen alike. The field is editable so
/// that a person can type the identity the same account already shows on another key;
/// read-only when the identity is already on the key and there is nothing to choose.
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
