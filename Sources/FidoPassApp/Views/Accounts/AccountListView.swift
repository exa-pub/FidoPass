import SwiftUI
import FidoPassCore

struct AccountListView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let devicePath: String

    var body: some View {
        let accounts = filteredAccounts
        List(selection: $viewModel.selected) {
            if accounts.isEmpty {
                AccountEmptyStateView(onCreate: { viewModel.showNewAccountSheet = true },
                                      onClearSearch: { withAnimation { viewModel.accountSearch = "" } })
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ForEach(accounts) { account in
                    AccountRowView(viewModel: viewModel, account: account)
                        .tag(account as Account?)
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand(perform: viewModel.requestDeleteSelectedAccount)
    }

    private var filteredAccounts: [Account] {
        let query = viewModel.accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.accounts.filter { account in
            guard account.devicePath == devicePath else { return false }
            guard !query.isEmpty else { return true }
            return account.id.localizedCaseInsensitiveContains(query)
            || account.rpId.localizedCaseInsensitiveContains(query)
        }
    }
}

struct AccountEmptyStateView: View {
    let onCreate: () -> Void
    let onClearSearch: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No accounts found")
                .font(.headline)
            Text("Create a new account or clear the search.")
                .font(.callout)
                .foregroundColor(.secondary)
            Button(action: onClearSearch) {
                Label("Clear search", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: onCreate) {
                Label("Create account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Text("Tip: press ⌘N to add quickly.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct AccountRowView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let account: Account
    @State private var isHovering = false

    var body: some View {
        let isPortable = account.rpId == "fidopass.portable"
        let isSelected = viewModel.selected?.id == account.id && viewModel.selected?.devicePath == account.devicePath
        let accentColor = isPortable ? Color.orange : Color.accentColor
        let iconFill = isPortable ? Color.orange : Color.accentColor
        let backgroundColor: Color = {
            if isSelected { return Color.accentColor.opacity(0.18) }
            if isHovering { return Color.primary.opacity(0.06) }
            return Color.clear
        }()
        let borderColor: Color = isSelected ? Color.accentColor.opacity(0.35) : Color.clear
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconFill.opacity(isSelected ? 0.28 : (isHovering ? 0.22 : 0.16)))
                    .frame(width: 40, height: 40)
                Image(systemName: "key.fill")
                    .foregroundColor(accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(account.id)
                    .font(.body.weight(.medium))
                    .foregroundColor(isSelected ? .accentColor : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(isSelected ? .accentColor.opacity(0.75) : .secondary)
            }
            Spacer()
            if viewModel.generatingAccountId == account.id {
                ProgressView().controlSize(.small)
            }
            if viewModel.selected?.id == account.id {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .onTapGesture { viewModel.selected = account }
        .onHover { hovering in isHovering = hovering }
        .contextMenu {
            Button(role: .destructive) {
                viewModel.accountPendingDeletion = account
                viewModel.showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button("Generate password") {
                viewModel.generatePassword(for: account, label: viewModel.labelInput)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(account.id), \(isPortable ? "Portable" : (account.rpId.isEmpty ? "No RP" : account.rpId))"))
        .accessibilityHint(Text("Select to view account details"))
    }

    private var subtitle: String {
        if account.rpId == "fidopass.portable" {
            return "Portable credential"
        }
        if account.rpId.isEmpty {
            return "Local credential"
        }
        if account.rpId == "fidopass.local" {
            return "Local credential"
        }
        return "Domain · \(account.rpId)"
    }
}
