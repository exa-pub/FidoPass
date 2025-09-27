import SwiftUI
import FidoPassCore

struct AccountDetailContainerView: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        KeyTouchPromptContainer(configuration: keyTouchPromptConfiguration) {
            Group {
                if let account = viewModel.selected,
                   let path = account.devicePath,
                   viewModel.deviceStates[path]?.unlocked == true {
                    ScrollView {
                        AccountDetailView(viewModel: viewModel, account: account)
                            .frame(maxWidth: 560, alignment: .leading)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    AccountDetailPlaceholderView()
                        .frame(maxWidth: 480)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(detailBackground)
        }
    }

    private var keyTouchPromptConfiguration: KeyTouchPromptConfiguration? {
        guard let account = activeAccount else { return nil }
        return KeyTouchPromptConfiguration(title: "Touch your security key to generate",
                                           message: "Keep the key in contact until the password appears.",
                                           accent: accentColor(for: account),
                                           accessory: accessory(for: account))
    }

    private var activeAccount: Account? {
        guard viewModel.generating,
              let id = viewModel.generatingAccountId,
              let selected = viewModel.selected,
              selected.id == id else { return nil }
        return selected
    }

    private func accessory(for account: Account) -> KeyTouchPromptConfiguration.Accessory? {
        guard let path = account.devicePath,
              let device = viewModel.deviceStates[path]?.device else {
            return .custom(account.id)
        }
        return .deviceName(device.displayName)
    }

    private func accentColor(for account: Account) -> Color {
        guard let path = account.devicePath,
              let device = viewModel.deviceStates[path]?.device else { return .accentColor }
        return DeviceColorPalette.color(for: device)
    }
}

private var detailBackground: Color {
    #if canImport(AppKit)
    return Color(nsColor: .underPageBackgroundColor)
    #elseif canImport(UIKit)
    return Color(UIColor.systemGroupedBackground)
    #else
    return Color.secondary.opacity(0.05)
    #endif
}
