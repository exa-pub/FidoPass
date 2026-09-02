import SwiftUI
import FidoPassCore

struct CredentialDetailView: View {
    let credential: ResidentCredential
    @State private var showsPublicKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ManagerSectionHeader(title: credential.listLabel)

            ManagerRow(label: "Relying party", value: credential.rpId, copyable: true)
            ManagerRow(label: "User name", value: credential.userName.display)
            ManagerRow(label: "Display name", value: credential.userDisplayName ?? "—")
            ManagerRow(label: "User id (hex)", value: credential.userIdHex.isEmpty ? "—" : credential.userIdHex,
                       monospaced: true, copyable: !credential.userIdHex.isEmpty)
            if let utf8 = credential.userIdUTF8, !utf8.isEmpty {
                ManagerRow(label: "User id (as text)", value: utf8)
            }
            ManagerRow(label: "Credential id", value: credential.credentialIdB64, monospaced: true, copyable: true)
            ManagerRow(label: "Algorithm",
                       value: credential.coseAlgorithm.map { "\(AuthenticatorInfo.algorithmName(cose: $0)) (\($0))" } ?? "not reported")
            ManagerRow(label: "Credential protection",
                       value: credential.credentialProtection?.summary ?? "not reported")
            ManagerRow(label: "Large blob key",
                       value: credential.hasLargeBlobKey ? "present — withheld" : "absent")

            if let publicKey = credential.publicKeyB64 {
                DisclosureGroup("Public key (\(publicKey.count) chars base64)", isExpanded: $showsPublicKey) {
                    Text(publicKey)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .font(.caption)
                .padding(.top, 10)
            }

            if case .portableKeyMaterialWithheld = credential.userName {
                Label("This is a FidoPass portable account. Its backup key is stored in the credential's user name, so this window does not show it — use the panel's backup-key screen, which explains what the value is before revealing it.",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Text("Signature counters, creation time and the extensions a credential uses are not part of what credential management returns, so they cannot be shown for any key.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }
}
