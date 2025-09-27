import Foundation
import FidoPassCore

extension AccountsViewModel {
    func enroll(accountId: String,
                rpId: String = "fidopass.local",
                requireUV: Bool = true) {
        guard let path = selectedDevicePath,
              let state = deviceStates[path],
              state.unlocked else {
            errorMessage = "Unlock the device first"
            return
        }
        let pin = state.pin
        enrollmentPhase = .waiting(message: "Touch your security key to confirm")
        let core = self.core
        weak var weakSelf = self
        Task.detached(priority: .userInitiated) {
            do {
                let account = try core.enroll(accountId: accountId,
                                              rpId: rpId,
                                              userName: "",
                                              requireUV: requireUV,
                                              residentKey: true,
                                              devicePath: path,
                                              askPIN: { pin })
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.accounts.append(account)
                    self.accounts.sort { $0.id < $1.id }
                    self.showToast("Account added", icon: "plus", style: .success)
                    self.enrollmentPhase = .idle
                    self.showNewAccountSheet = false
                }
            } catch {
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.errorMessage = error.localizedDescription
                    self.enrollmentPhase = .failure(message: error.localizedDescription)
                }
            }
        }
    }

    func enrollPortable(accountId: String,
                        importedKeyB64: String?) {
        guard let path = selectedDevicePath,
              let state = deviceStates[path],
              state.unlocked else {
            errorMessage = "Unlock the device first"
            return
        }
        let pin = state.pin
        enrollmentPhase = .waiting(message: "Touch your security key to confirm portable enrollment")
        let core = self.core
        weak var weakSelf = self
        Task.detached(priority: .userInitiated) {
            do {
                let result = try core.enrollPortable(accountId: accountId,
                                                     requireUV: true,
                                                     devicePath: path,
                                                     askPIN: { pin },
                                                     importedKeyB64: importedKeyB64)
                let account = result.0
                let generated = result.1
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.accounts.append(account)
                    self.accounts.sort { $0.id < $1.id }
                    if let generated {
                        self.generatedPassword = "IMPORTED:" + generated
                    }
                    self.showToast("Portable account ready", icon: "key.horizontal", style: .success)
                    self.enrollmentPhase = .idle
                    self.showNewAccountSheet = false
                }
            } catch {
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.errorMessage = error.localizedDescription
                    self.enrollmentPhase = .failure(message: error.localizedDescription)
                }
            }
        }
    }

    func deleteAccount(_ account: Account) {
        guard let path = account.devicePath,
              let state = deviceStates[path],
              state.unlocked else { return }
        let pin = state.pin
        Task {
            do {
                try core.deleteAccount(account, pin: pin)
                await MainActor.run {
                    accounts.removeAll { $0.id == account.id && $0.devicePath == path }
                    if selected?.id == account.id {
                        selected = nil
                    }
                    self.showToast("Account deleted", icon: "trash", style: .warning)
                }
                await MainActor.run { self.reload() }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }
}
