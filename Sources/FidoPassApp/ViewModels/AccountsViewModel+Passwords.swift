import Foundation
import FidoPassCore

extension AccountsViewModel {
    func generatePassword(for account: Account, label: String) {
        performPasswordGeneration(for: account, label: label) { viewModel, password in
            viewModel.generatedPassword = password
            viewModel.generatedForLabel = label
            if !label.isEmpty { viewModel.addRecentLabel(label) }
            viewModel.showToast("Password generated", icon: "wand.and.stars", style: .success)
        }
    }

    func generatePasswordAndCopy(for account: Account, label: String) {
        showPlainPassword = false
        performPasswordGeneration(for: account, label: label) { viewModel, password in
            // Keep the result visible too. Copying used to leave the panel reading "No
            // password generated yet" even though a password was on the clipboard.
            viewModel.generatedPassword = password
            viewModel.generatedForLabel = label
            if !label.isEmpty { viewModel.addRecentLabel(label) }
            viewModel.copyGeneratedPassword(password)
        }
    }

    /// Copies a secret and records it against the account it belongs to.
    func copyGeneratedPassword(_ password: String) {
        recordCopy(of: .password, secret: password)
        showToast("Password copied",
                  icon: "doc.on.doc.fill",
                  style: .success,
                  subtitle: "Clipboard clears in \(Int(ClipboardService.defaultClearInterval))s")
    }

    /// Copies a backup key. Same clipboard hygiene as a password, different wording, so
    /// the toast can never be mistaken for "your password is ready".
    func copyBackupKey(_ key: String) {
        recordCopy(of: .backupKey, secret: key)
        showToast("Backup key copied",
                  icon: "key.horizontal",
                  style: .warning,
                  subtitle: "Clipboard clears in \(Int(ClipboardService.defaultClearInterval))s — store it offline")
    }

    private func recordCopy(of item: CopyReceipt.Item, secret: String) {
        guard let account = selected else { return }
        let deadline = ClipboardService.copySecret(secret) { [weak self] in
            Task { @MainActor in
                // Stop advertising a countdown for a clipboard that no longer holds it.
                self?.copyReceipt?.clearsAt = nil
            }
        }
        copyReceipt = CopyReceipt(accountId: account.id,
                                  devicePath: account.devicePath,
                                  item: item,
                                  copiedAt: Date(),
                                  clearsAt: deadline)
    }

    /// Drops a shown password once it no longer matches what the label field says.
    ///
    /// The panel used to keep displaying a password derived from a previous label, so
    /// editing the label and hitting copy handed over the wrong secret.
    func invalidateGeneratedPasswordIfLabelChanged() {
        guard generatedPassword != nil, generatedForLabel != labelInput else { return }
        generatedPassword = nil
        generatedForLabel = nil
        showPlainPassword = false
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

        guard let pinProvider = makePinProvider(for: account.devicePath) else {
            generating = false
            generatingAccountId = nil
            showToast("Unlock required", icon: "lock.fill", style: .warning, subtitle: "Unlock the device to generate a password")
            return
        }

        let core = self.core
        weak var weakSelf = self

        Task.detached(priority: .userInitiated) {
            do {
                let password = try core.generatePassword(account: account,
                                                          label: label,
                                                          requireUV: true,
                                                          pinProvider: pinProvider)
                await MainActor.run {
                    guard let viewModel = weakSelf else { return }
                    success(viewModel, password)
                }
            } catch {
                await MainActor.run {
                    guard let viewModel = weakSelf else { return }
                    viewModel.errorMessage = FidoPassErrorPresenter.message(for: error).fullText()
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
