import SwiftUI
import FidoPassCore

/// Discoverable credentials grouped by relying party, with details for the selected row.
struct CredentialsBrowserView: View {
    let inventory: CredentialInventory
    @Binding var selection: String?

    private var selected: ResidentCredential? {
        guard let selection else { return nil }
        return inventory.allCredentials.first { $0.credentialIdB64 == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 280)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            if inventory.relyingParties.isEmpty {
                VStack(spacing: 6) {
                    Text("No discoverable credentials").font(.caption).foregroundStyle(.secondary)
                    Text(CredentialInventory.undiscoverableCaveat)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(inventory.relyingParties) { party in
                        Section {
                            ForEach(party.credentials) { credential in
                                row(credential).tag(credential.credentialIdB64)
                            }
                            if party.credentials.isEmpty {
                                Text(inventory.unreadableRelyingParties[party.id] ?? "No credentials listed.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        } header: {
                            HStack {
                                Text(party.id).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text("\(party.credentials.count)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            footer
        }
    }

    private func row(_ credential: ResidentCredential) -> some View {
        HStack(spacing: 7) {
            Image(systemName: credential.isFidoPassCredential ? "key.fill" : "person.crop.circle")
                .font(.caption)
                .foregroundStyle(credential.isFidoPassCredential ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(credential.listLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let name = credential.userName.revealed, name != credential.listLabel {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // The same swatch the panel shows, so a row here and a row there can be matched
            // by eye.
            if let identity = credential.accountIdentity {
                IdentityFingerprintView(identity: identity, style: .swatch)
            }
            Spacer(minLength: 0)
            if credential.credentialProtection == .uvRequired {
                Image(systemName: "lock.shield")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Credential protection 3 — user verification required")
            }
        }
        .padding(.vertical, 1)
    }

    /// The slot count belongs next to the list it appears to explain, together with the
    /// sentence that stops it from being read as "everything on this key".
    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let used = inventory.residentKeysUsed, let remaining = inventory.residentKeysRemaining {
                Text("\(used) of \(used + remaining) credential slots used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(CredentialInventory.undiscoverableCaveat)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected {
            ScrollView {
                CredentialDetailView(credential: selected)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 6) {
                Text("Select a credential").font(.system(size: 13, weight: .semibold))
                Text("Its relying party, user entity, algorithm and protection level are shown here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }
}
