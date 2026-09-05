import SwiftUI
import FidoPassCore

/// The account list: one expanded row with the generator, the rest one line each.
///
/// Expanding only the selected account is what keeps the panel compact while leaving the
/// daily action — copy the password — a single click away.
struct AccountsSectionView: View {
    @ObservedObject var store: PanelStore
    @ObservedObject var accounts: AccountStore
    @ObservedObject var generation: GenerationStore
    @ObservedObject var labels: LabelStore

    var body: some View {
        let visible = store.visibleAccounts
        if visible.isEmpty {
            EmptyAccountsView(onCreate: { store.show(.enroll) })
        } else {
            VStack(spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.element) { index, account in
                    let ref = AccountRef(account)
                    AccountRowView(store: store,
                                   generation: generation,
                                   labels: labels,
                                   editor: store.labelEditor,
                                   account: account,
                                   ref: ref,
                                   index: index,
                                   isSelected: store.selection == ref,
                                   isOnlyAccount: visible.count == 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

struct EmptyAccountsView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No accounts on this key")
                .font(.system(size: 13, weight: .semibold))
            Text("Create an account for a vault master password, a disk key or a backup passphrase.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create account", action: onCreate)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }
}

struct AccountRowView: View {
    @ObservedObject var store: PanelStore
    @ObservedObject var generation: GenerationStore
    @ObservedObject var labels: LabelStore
    @ObservedObject var editor: LabelEditor
    let account: AccountHandle
    let ref: AccountRef
    let index: Int
    let isSelected: Bool
    let isOnlyAccount: Bool

    @State private var isHovering = false

    private var result: GenerationStore.Result? {
        guard let result = generation.result, result.ref == ref else { return nil }
        return result
    }

    private var isBusy: Bool { generation.busyRef == ref }

    /// How the row is drawn and what it offers. Four cases besides the ordinary one, and
    /// every one of them replaces the generator with the one thing there is to do.
    private var state: AccountRowState { AccountRowState(account, store: store) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isSelected {
                switch state {
                case .ready:
                    labelRow
                    actionRow
                    if let result {
                        ResultView(result: result,
                                   generation: generation,
                                   onToggleReveal: store.toggleReveal,
                                   onCopy: store.copyCurrentResult)
                    }
                case .needsMigration, .unfinishedMigration:
                    migrationRow
                case .incomplete:
                    incompleteRow
                case .notMigratable:
                    notMigratableNote
                    labelRow
                    actionRow
                    if let result {
                        ResultView(result: result,
                                   generation: generation,
                                   onToggleReveal: store.toggleReveal,
                                   onCopy: store.copyCurrentResult)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isSelected ? 9 : 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : (isHovering ? Color.primary.opacity(0.06) : .clear))
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isSelected { store.select(ref) } }
        .onHover { isHovering = $0 }
        // Rare actions live here: keeping visible buttons for a yearly operation would cost
        // permanent space in a 340 pt panel.
        .contextMenu { AccountActionsMenu(store: store, account: account, ref: ref) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.id), \(account.kind == .portable ? "portable" : "local") credential\(state.accessibilitySuffix)")
    }

    /// The name line, with the identity as a small swatch beside the tag. The hex lives in
    /// the tooltip on both — the list is for telling accounts apart at a glance, not for
    /// reading them out, and a strip across the row made every row a banner.
    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(account.id)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(state.isDimmed ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(identityTooltip)
            KindTag(kind: account.kind, state: state)
            if account.account.format == .v1, state == .ready {
                FormatTag()
            }
            Spacer(minLength: 0)

            // At the trailing edge, so that the swatches of several rows line up under each
            // other — that is where they get compared.
            if let identity = account.account.identity {
                IdentityFingerprintView(identity: identity, style: .swatch)
            }

            // A slot of one width for whatever sits at the edge — the menu, the ⌘n hint or
            // nothing — otherwise the swatch moves with it and the column is lost.
            trailingControl
                .frame(width: 26, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isHovering || isSelected {
            Menu {
                AccountActionsMenu(store: store, account: account, ref: ref)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for this account")
        } else if !isOnlyAccount {
            Text("⌘\(index + 1)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var tint: Color {
        if state.isDimmed { return .secondary }
        return account.kind == .portable ? .orange : .accentColor
    }

    private var identityTooltip: String {
        if let identity = account.account.identity { return "Identity \(identity.groupedHex)" }
        return "Created by an earlier version — migrate to give it an identity"
    }

    /// What a v1 portable account offers instead of the generator: the one thing to do
    /// with it — or, when a copy is already on the key, finishing that.
    private var migrationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state == .unfinishedMigration
                 ? "An earlier migration left a copy on the key — finish it, or discard the copy."
                 : "Created by an earlier version — migrate to use. The same passwords, in the current layout; four touches.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                store.beginMigration(ref)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.circle").font(.system(size: 10))
                    Text(state == .unfinishedMigration ? "Finish migration" : "Migrate")
                    Text("⏎")
                        .font(.system(size: 10))
                        .opacity(0.7)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(isSelected ? .defaultAction : nil)
            .help("Recreate this account in the current layout (⏎)")
        }
    }

    /// A credential without a usable record: not an account, and only deletable.
    private var incompleteRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(account.account.integrity.problem ?? "This account cannot be used.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete…") { store.show(.confirmDelete(ref)) }
                .controlSize(.small)
        }
    }

    /// A v1 portable account on a key that cannot take the copy: it derives as it always
    /// did, and says why nothing more is offered.
    private var notMigratableNote: some View {
        Text("Created by an earlier version. This key cannot hold the current layout, so the account stays as it is — passwords work, encryption keys do not.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var labelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Label").font(.caption).foregroundStyle(.secondary)
            LabelTextField(text: Binding(get: { editor.draft }, set: { editor.draftChanged($0) }),
                           isFocused: Binding(get: { editor.isEditing }, set: { editor.setEditing($0) }),
                           placeholder: "Enter a label…",
                           caretAtEnd: editor.caretAtEnd,
                           onSubmit: { Task { await store.copyPassword(for: ref) } },
                           onCancel: { _ = editor.escape() },
                           onExitLeft: { editor.moveFocus(by: -1) },
                           onExitRight: { editor.moveFocus(by: 1) },
                           onMoveAccount: { store.moveSelection(by: $0) })
                .frame(height: 24)
                .accessibilityLabel("Password label")

            HStack(spacing: 4) {
                Text("Recent").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(labels.chips.enumerated()), id: \.offset) { _, label in
                    LabelChip(label: LabelDisplay.text(label), isCurrent: false,
                              action: { store.setLabel(label) })
                        .help("Use exactly these label bytes: " + label.utf8.map { String(format: "%02x", $0) }.joined(separator: " "))
                }
                if !labels.chips.contains(LabelStore.fallback) {
                    Button("default") { store.setLabel(LabelStore.fallback) }.buttonStyle(.link).font(.caption2)
                }
            }
            if let issue = editor.issue {
                Text(issue).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editor.needsWhitespaceChoice {
                Text("“\(LabelDisplay.text(editor.current))” · \(editor.current.utf8.count) bytes. Earlier versions removed surrounding whitespace.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Button("Use without surrounding whitespace") { editor.useTrimmedLabel() }
                    Button("Keep exact label") { editor.keepExactLabel() }
                }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            Button {
                Task { await store.copyPassword(for: ref) }
            } label: {
                HStack(spacing: 5) {
                    if isBusy {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "doc.on.doc.fill").font(.system(size: 10))
                    }
                    Text("Copy password")
                    Text("⏎")
                        .font(.system(size: 10))
                        .opacity(0.7)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(isSelected ? .defaultAction : nil)
            .disabled(store.isWorking || !editor.canGenerate)
            .help("Generate the password and put it on the clipboard (⏎)")

            Button {
                Task { await store.revealPassword(for: ref) }
            } label: {
                Image(systemName: "eye")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .disabled(store.isWorking || !editor.canGenerate)
            .help("Generate and show it on screen instead of copying (⌘⏎)")
        }
    }
}

/// What a row is, beyond its kind — and what it may offer.
enum AccountRowState: Equatable {
    /// Derives; the ordinary case.
    case ready
    /// A v1 portable account on a key that can take the v2 copy: migrate first.
    case needsMigration
    /// A v1 portable account whose copy is already on the key: finish or discard.
    case unfinishedMigration
    /// A v1 portable account on a key without a large-blob store: derives as before, and
    /// that is all it will ever do.
    case notMigratable
    /// A credential without a usable record: delete.
    case incomplete

    @MainActor
    init(_ handle: AccountHandle, store: PanelStore) {
        if !handle.account.canDerive {
            self = .incomplete
        } else if handle.account.needsMigration {
            if !store.isMigratable(handle) {
                self = .notMigratable
            } else if store.accounts.migrationCopy(for: AccountRef(handle)) != nil {
                self = .unfinishedMigration
            } else {
                self = .needsMigration
            }
        } else {
            self = .ready
        }
    }

    var isDimmed: Bool { self == .needsMigration || self == .unfinishedMigration || self == .incomplete }

    var accessibilitySuffix: String {
        switch self {
        case .ready: return ""
        case .needsMigration: return ", needs migration"
        case .unfinishedMigration: return ", unfinished migration"
        case .notMigratable: return ", earlier version"
        case .incomplete: return ", incomplete"
        }
    }
}

struct KindTag: View {
    let kind: AccountKind
    var state: AccountRowState = .ready

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private var text: String {
        switch state {
        case .ready, .notMigratable: return kind == .portable ? "portable" : "local"
        case .needsMigration: return "needs migration"
        case .unfinishedMigration: return "unfinished migration"
        case .incomplete: return "incomplete"
        }
    }

    private var tint: Color {
        if state.isDimmed { return .secondary }
        return kind == .portable ? .orange : .accentColor
    }
}

/// Marks an account still in the v1 layout that works as it is: a local one, which cannot
/// move, or a portable one on a key that cannot take the move.
struct FormatTag: View {
    var body: some View {
        Text("v1")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.16), in: Capsule())
            .foregroundStyle(.secondary)
            .help("Created by an earlier version. Works as before; not available in the browser.")
    }
}

/// One recent label: a click away, no menu to open.
struct LabelChip: View {
    let label: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .background {
            Capsule().fill(isCurrent ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
        }
        .overlay {
            Capsule().stroke(isCurrent ? Color.accentColor.opacity(0.5) : .clear)
        }
        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
        .help("Use the label “\(label)”")
    }
}

/// The generated password, and the life of the clipboard copy.
struct ResultView: View {
    let result: GenerationStore.Result
    @ObservedObject var generation: GenerationStore
    let onToggleReveal: () -> Void
    /// Copying an already-derived password costs no touch — regenerating it would.
    let onCopy: () -> Void

    private var receipt: ClipboardReceipt? {
        guard let receipt = generation.receipt, receipt.ref == result.ref else { return nil }
        return receipt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(result.ref.accountId) · label “\(LabelDisplay.text(result.label))”")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(result.revealed ? result.password : String(repeating: "•", count: min(result.password.count, 24)))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                Button(action: onToggleReveal) {
                    Image(systemName: result.revealed ? "eye.slash" : "eye").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(result.revealed ? "Hide" : "Reveal")

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Copy this password again — no touch needed")
            }

            if let seconds = generation.secondsUntilClear, receipt != nil {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(seconds), total: ClipboardService.defaultClearInterval)
                        .progressViewStyle(.linear)
                        .tint(seconds <= 10 ? .orange : .accentColor)
                    Text("\(receipt?.item.noun ?? "Password") on the clipboard — clears in \(seconds)s")
                        .font(.system(size: 10))
                        .foregroundStyle(seconds <= 10 ? .orange : .secondary)
                }
            } else if receipt != nil {
                Text("Clipboard cleared")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            } else {
                Text("label “\(result.label)” — shown on screen only")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One menu, reachable two ways: right-click on the row, or the hover `···`.
struct AccountActionsMenu: View {
    @ObservedObject var store: PanelStore
    let account: AccountHandle
    let ref: AccountRef

    var body: some View {
        let state = AccountRowState(account, store: store)
        if state == .incomplete {
            Button("Delete account…") { store.show(.confirmDelete(ref)) }
        } else if state == .needsMigration || state == .unfinishedMigration {
            // Nothing is derived from a v1 portable account until it has been migrated —
            // except its backup, which is the one thing that must never wait.
            Button(state == .unfinishedMigration ? "Finish migration…" : "Migrate…") { store.beginMigration(ref) }
            Divider()
            Button("Backup key…") { Task { await store.showBackupKey(for: ref) } }
            Button("Save recovery sheet…") { store.saveRecoverySheet(for: ref) }
            Divider()
            Button("Delete account…") { store.show(.confirmDelete(ref)) }
        } else {
            Button("Copy password") { Task { await store.copyPassword(for: ref) } }
            Button("Reveal password") { Task { await store.revealPassword(for: ref) } }
            Divider()
            Button("Encryption key…") { Task { await store.issueEncryptionKey(for: ref) } }
            Button("Save recovery sheet…") { store.saveRecoverySheet(for: ref) }
            if account.kind == .portable {
                Button("Backup key…") { Task { await store.showBackupKey(for: ref) } }
            }
            if account.account.identity != nil {
                Button("Copy identity") { store.copyIdentity(for: ref) }
            }
            Divider()
            Button("Delete account…") { store.show(.confirmDelete(ref)) }
        }
    }
}
