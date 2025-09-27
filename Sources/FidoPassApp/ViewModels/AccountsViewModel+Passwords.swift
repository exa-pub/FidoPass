import Foundation
import FidoPassCore

extension AccountsViewModel {
    func generatePassword(for account: Account, label: String) {
        generating = true
        generatingAccountId = account.id
        generatedPassword = nil
        let pin = deviceStates[account.devicePath ?? ""]?.pin
        Task {
            do {
                let password = try core.generatePassword(account: account,
                                                          label: label,
                                                          requireUV: true,
                                                          pinProvider: { pin })
                await MainActor.run {
                    self.generatedPassword = password
                    if !label.isEmpty { self.addRecentLabel(label) }
                    self.showToast("Password generated", icon: "wand.and.stars", style: .success)
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run {
                self.generating = false
                self.generatingAccountId = nil
            }
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
}
