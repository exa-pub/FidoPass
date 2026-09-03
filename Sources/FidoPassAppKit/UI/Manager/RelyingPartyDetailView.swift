import SwiftUI
import FidoPassCore

struct RelyingPartyDetailView: View {
    let party: CredentialInventory.RelyingParty
    let unreadableReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ManagerSectionHeader(title: party.id)
            ManagerRow(label: "Relying party id", value: party.id, copyable: true)
            // Almost always absent: authenticators tested so far keep no relying-party name,
            // even for credentials created with one.
            ManagerRow(label: "Name", value: party.name ?? "not stored by the key")
            ManagerRow(label: "RP id hash (SHA-256)", value: party.idHashHex.isEmpty ? "not reported" : party.idHashHex,
                       monospaced: true)
            ManagerRow(label: "Discoverable credentials", value: "\(party.credentials.count)")

            if let unreadableReason {
                Label("This relying party's credentials could not be read: \(unreadableReason)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 10)
            }
        }
    }
}
