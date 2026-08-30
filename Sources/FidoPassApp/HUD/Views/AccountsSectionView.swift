import SwiftUI
import FidoPassCore

/// The account list: one expanded row with the generator, the rest one line each.
///
/// Expanding only the selected account is what keeps the panel compact while leaving the
/// daily action — copy the password — a single click away.
struct AccountsSectionView: View {
    @ObservedObject var store: HUDStore
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
                    if let ref = AccountRef(account) {
                        AccountRowView(store: store,
                                       generation: generation,
                                       labels: labels,
                                       account: account,
                                       ref: ref,
                                       index: index,
                                       isSelected: store.selection == ref,
                                       isOnlyAccount: visible.count == 1)
                    }
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
            Text("An account is one derivation identity — a vault master password, a disk key. One or two is the normal number.")
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
    @ObservedObject var store: HUDStore
    @ObservedObject var generation: GenerationStore
    @ObservedObject var labels: LabelStore
    let account: Account
    let ref: AccountRef
    let index: Int
    let isSelected: Bool
    let isOnlyAccount: Bool

    @State private var isHovering = false
    /// Text of the inline custom field. Empty whenever the current label is one of the chips.
    @State private var customText = ""

    private var result: GenerationStore.Result? {
        guard let result = generation.result, result.ref == ref else { return nil }
        return result
    }

    private var isBusy: Bool { generation.busyRef == ref }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isSelected {
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
        .accessibilityLabel("\(account.id), \(account.kind == .portable ? "portable" : "local") credential")
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(account.kind == .portable ? Color.orange : Color.accentColor)
            Text(account.id)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            KindTag(kind: account.kind)
            Spacer(minLength: 0)

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
    }

    /// Chips and the field for anything else, on one line: the recent labels and "something
    /// I have not used before" are the same choice, and splitting them behind a mode switch
    /// made the second one look like a different feature.
    private var labelRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LABEL")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            HStack(spacing: 4) {
                ForEach(labels.chips, id: \.self) { label in
                    LabelChip(label: label,
                              isCurrent: label == labels.current && !store.isEditingLabel,
                              action: {
                                  store.isEditingLabel = false
                                  store.setLabel(label)
                              })
                }

                LabelTextField(text: $customText,
                               isFocused: Binding(get: { store.isEditingLabel },
                                                  set: { store.isEditingLabel = $0 }),
                               placeholder: "custom…",
                               caretAtEnd: store.labelFieldCaretAtEnd,
                               onSubmit: {
                                   // Leaving the field lets the label graduate into a chip
                                   // instead of sitting on screen twice, as text and as chip.
                                   store.isEditingLabel = false
                                   Task { await store.copyPassword(for: ref) }
                               },
                               onExitLeft: { store.moveLabelFocus(by: -1) },
                               onExitRight: { store.moveLabelFocus(by: 1) },
                               onMoveAccount: { store.moveSelection(by: $0) })
                    .frame(minWidth: 64, maxHeight: 20)
            }
        }
        .onAppear(perform: syncCustomField)
        .onChange(of: labels.current) { _ in syncCustomField() }
        .onChange(of: store.isEditingLabel) { isEditing in
            syncCustomField()
            // Stepping back into the field means going back to what was typed there.
            let draft = customText.trimmingCharacters(in: .whitespacesAndNewlines)
            if isEditing, !draft.isEmpty { store.setLabel(draft) }
        }
        .onChange(of: customText) { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            store.setLabel(trimmed)
        }
    }

    /// Text typed here is a draft: it survives losing focus and picking a chip, because
    /// retyping a label is exactly the mistake that derives a different password.
    private func syncCustomField() {
        guard !store.isEditingLabel, !labels.chips.contains(labels.current) else { return }
        customText = labels.current
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
            .disabled(isBusy)
            .help("Generate the password and put it on the clipboard (⏎)")

            Button {
                Task { await store.revealPassword(for: ref) }
            } label: {
                Image(systemName: "eye")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .help("Generate and show it on screen instead of copying (⌘⏎)")
        }
    }
}

struct KindTag: View {
    let kind: AccountKind

    var body: some View {
        Text(kind == .portable ? "portable" : "local")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((kind == .portable ? Color.orange : Color.accentColor).opacity(0.16),
                        in: Capsule())
            .foregroundStyle(kind == .portable ? Color.orange : Color.accentColor)
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
            HStack(spacing: 6) {
                Text(result.revealed ? result.password : String(repeating: "•", count: min(result.password.count, 24)))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
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
    @ObservedObject var store: HUDStore
    let account: Account
    let ref: AccountRef

    var body: some View {
        Button("Copy password") { Task { await store.copyPassword(for: ref) } }
        Button("Reveal password") { Task { await store.revealPassword(for: ref) } }
        Divider()
        Button("Encrypt text…") { Task { await store.openEncryptEditor(for: ref) } }
        Button("Save recovery sheet…") { store.saveRecoverySheet(for: ref) }
        if account.kind == .portable {
            Button("Backup key…") { Task { await store.showBackupKey(for: ref) } }
        }
        Divider()
        Button("Delete account…") { store.show(.confirmDelete(ref)) }
    }
}
