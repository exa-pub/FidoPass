import Foundation
import FidoPassCore

extension AccountsViewModel {
    func enroll(accountId: String,
                kind: AccountKind = .local,
                requireUV: Bool = true) {
        guard let path = selectedDevicePath,
              let state = deviceStates[path],
              state.unlocked else {
            errorMessage = "Unlock the device first"
            return
        }
        guard let pinProvider = makePinProvider(for: path) else {
            errorMessage = "Unlock the device first"
            return
        }
        enrollmentPhase = .waiting(message: "Touch your security key to confirm")
        let core = self.core
        weak var weakSelf = self
        Task.detached(priority: .userInitiated) {
            do {
                let account = try core.enroll(accountId: accountId,
                                              kind: kind,
                                              requireUV: requireUV,
                                              devicePath: path,
                                              askPIN: pinProvider)
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
                    let presented = FidoPassErrorPresenter.message(for: error)
                    self.errorMessage = presented.fullText()
                    self.enrollmentPhase = .failure(message: presented.fullText())
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
        guard let pinProvider = makePinProvider(for: path) else {
            errorMessage = "Unlock the device first"
            return
        }
        enrollmentPhase = .waiting(message: Self.portableStepMessage(.creatingCredential))
        let core = self.core
        weak var weakSelf = self
        Task.detached(priority: .userInitiated) {
            do {
                let result = try core.enrollPortable(accountId: accountId,
                                                     requireUV: true,
                                                     devicePath: path,
                                                     askPIN: pinProvider,
                                                     importedKeyB64: importedKeyB64) { step in
                    Task { @MainActor in
                        weakSelf?.enrollmentPhase = .waiting(message: Self.portableStepMessage(step))
                    }
                }
                let account = result.0
                let generated = result.1
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.accounts.append(account)
                    self.accounts.sort { $0.id < $1.id }
                    if let generated {
                        // Shown in a dedicated sheet, not in the password field: this is
                        // the master key that reproduces every password of this account,
                        // and it must never look like something to paste into a login box.
                        self.exportedMasterKey = MasterKeyExport(accountId: accountId,
                                                                 key: generated,
                                                                 reason: .created)
                    }
                    self.showToast("Portable account ready", icon: "key.horizontal", style: .success)
                    self.enrollmentPhase = .idle
                    self.showNewAccountSheet = false
                }
            } catch {
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    let presented = FidoPassErrorPresenter.message(for: error)
                    self.errorMessage = presented.fullText()
                    self.enrollmentPhase = .failure(message: presented.fullText())
                }
            }
        }
    }

    /// Recovers the master key of a portable account.
    ///
    /// Lives here rather than in the view: the operation needs a touch of the key, and the
    /// view-side version forgot to raise the touch prompt, so the app simply appeared to
    /// hang for several seconds.
    func exportMasterKey(for account: Account) {
        guard let pinProvider = makePinProvider(for: account.devicePath) else {
            if let path = account.devicePath { handlePinExpiration(for: path, notify: true) }
            return
        }
        generating = true
        generatingAccountId = account.id
        let core = self.core
        weak var weakSelf = self
        Task.detached(priority: .userInitiated) {
            do {
                let key = try core.exportImportedKey(account, requireUV: true, pinProvider: pinProvider)
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.exportedMasterKey = MasterKeyExport(accountId: account.id, key: key, reason: .exported)
                }
            } catch {
                await MainActor.run {
                    weakSelf?.errorMessage = FidoPassErrorPresenter.message(for: error).fullText()
                }
            }
            await MainActor.run {
                weakSelf?.generating = false
                weakSelf?.generatingAccountId = nil
            }
        }
    }

    static func portableStepMessage(_ step: PortableEnrollmentStep) -> String {
        switch step {
        case .creatingCredential: return "Step 1 of 2 — touch your key to create the credential"
        case .derivingBackupKey:  return "Step 2 of 2 — touch your key again to derive its backup key"
        case .savingPayload:      return "Saving to the key…"
        }
    }

    func deleteAccount(_ account: Account) {
        guard let path = account.devicePath,
              let state = deviceStates[path],
              state.unlocked else { return }
        guard let pin = currentPin(forDevicePath: path) else {
            handlePinExpiration(for: path, notify: true)
            return
        }
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
                await MainActor.run { self.errorMessage = FidoPassErrorPresenter.message(for: error).fullText() }
            }
        }
    }
}
