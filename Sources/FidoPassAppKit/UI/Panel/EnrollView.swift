import SwiftUI
import FidoPassCore

/// Creating an account. Portable is the default because losing the only key that can derive
/// a vault master password is unrecoverable.
struct EnrollView: View {
    @ObservedObject var store: PanelStore

    private enum Field: Hashable { case accountId, importedKey }
    @FocusState private var focus: Field?

    /// The backup-key field is only on screen for a portable account, so Tab must not stop
    /// at a field that is not there.
    private var fields: [Field] {
        store.enrollDraft.kind == .portable ? [.accountId, .importedKey] : [.accountId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: "New account", subtitle: store.selectedDevice?.displayName) {
                store.backToAccounts()
            }

            VStack(alignment: .leading, spacing: 9) {
                TextField("Account ID, e.g. vault", text: $store.enrollDraft.accountId)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .accountId)
                    .onSubmit { Task { await store.createAccount() } }

                Picker("", selection: $store.enrollDraft.kind) {
                    Text("Portable").tag(AccountKind.portable)
                    Text("Local").tag(AccountKind.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(store.enrollDraft.kind == .portable
                     ? "Can be copied onto a second key, so these passwords survive losing this one. Recommended."
                     : "Bound to this key alone. If it is lost or reset, these passwords cannot be recovered by any means.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.enrollDraft.kind == .portable {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Existing backup key (optional, base64)", text: $store.enrollDraft.importedKeyB64)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .focused($focus, equals: .importedKey)
                        if let error = store.enrollDraft.importedKeyError {
                            Text(error).font(.caption2).foregroundStyle(.red)
                        } else {
                            Text("Leave empty to create a fresh key. Fill it in to make this key derive the same passwords as another one.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let step = store.enrollStep {
                    Label(step, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { store.backToAccounts() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") { Task { await store.createAccount() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.enrollDraft.canCreate || store.isWorking)
                }
            }
            .padding(.horizontal, PanelMetrics.padding)
            .padding(.bottom, 12)
        }
        .tabFocusChain(fields, focus: $focus)
        .onAppear { focus = .accountId }
    }
}
