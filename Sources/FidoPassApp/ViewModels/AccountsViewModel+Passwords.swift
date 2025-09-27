import Foundation
import FidoPassCore

extension AccountsViewModel {
    func generatePassword(for account: Account, label: String) {
        performPasswordGeneration(for: account, label: label) { viewModel, password in
            viewModel.generatedPassword = password
            if !label.isEmpty { viewModel.addRecentLabel(label) }
            viewModel.showToast("Password generated", icon: "wand.and.stars", style: .success)
        }
    }

    func generatePasswordAndCopy(for account: Account, label: String) {
        showPlainPassword = false
        performPasswordGeneration(for: account, label: label) { viewModel, password in
            ClipboardService.copy(password)
            viewModel.markPasswordCopied()
        }
    }

    func markPasswordCopied() {
        lastCopiedPasswordAt = Date()
        showToast("Password copied", icon: "doc.on.doc.fill", style: .success)
    }

    func requestSearchFocus() {
        focusSearchFieldToken &+= 1
    }

    func showToast(_ title: String,
                   icon: String? = nil,
                   style: ToastMessage.Style = .info,
                   subtitle: String? = nil,
                   duration: TimeInterval = 3.0) {
        toastTask?.cancel()
        let toast = ToastMessage(icon: icon,
                                 title: title,
                                 subtitle: subtitle,
                                 style: style)
        toastMessage = toast
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                if self?.toastMessage?.id == toast.id {
                    self?.toastMessage = nil
                }
            }
        }
    }

    private func performPasswordGeneration(for account: Account,
                                            label: String,
                                            success: @escaping (AccountsViewModel, String) -> Void) {
        generating = true
        generatingAccountId = account.id
        generatedPassword = nil

        let pin = deviceStates[account.devicePath ?? ""]?.pin
        let core = self.core
        weak var weakSelf = self

        Task.detached(priority: .userInitiated) {
            do {
                let password = try core.generatePassword(account: account,
                                                          label: label,
                                                          requireUV: true,
                                                          pinProvider: { pin })
                await MainActor.run {
                    guard let viewModel = weakSelf else { return }
                    success(viewModel, password)
                }
            } catch {
                await MainActor.run {
                    guard let viewModel = weakSelf else { return }
                    viewModel.errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                guard let viewModel = weakSelf else { return }
                viewModel.generating = false
                viewModel.generatingAccountId = nil
            }
        }
    }
}
