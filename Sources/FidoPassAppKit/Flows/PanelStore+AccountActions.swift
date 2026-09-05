import FidoPassCore
import Foundation

extension PanelStore {
    // MARK: - Enrolment

    func createAccount() async {
        guard !isWorking else { return }
        guard let request = enrollDraft.request,
              let identity = enrollDraft.identity,
              let path = devices.selectedPath,
              let device = selectedDevice,
              selectedKeyHoldsRecords else { return }
        guard !selectedKeyIsFull else {
            error = .plain("This key has no free credential slots. Open Manage this key to review its accounts, or read the key again if its contents changed.")
            return
        }
        let draft = enrollDraft
        let flowLease = accountFlowLease
        error = nil

        do {
            let created = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                                message: request.kind == .portable
                                                                    ? "Step 1 of 2 — creating the credential."
                                                                    : "Confirming with the key.",
                                                                deviceName: device.displayName)) {
                let promptLease = KeyOperationContext.lease
                return try await self.accounts.enroll(accountId: draft.trimmedId,
                                               identity: identity,
                                               request: request,
                                               devicePath: path) { step in
                    Task { @MainActor in
                        guard flowLease.isValid else { return }
                        self.enrollStep = Self.stepMessage(step)
                        self.touchGate.updatePrompt(message: Self.stepMessage(step), ownedBy: promptLease)
                    }
                }
            }
            try KeyOperationContext.check(flowLease)
            error = nil
            enrollStep = nil
            enrollDraft = EnrollDraft()
            select(AccountRef(created.0))

            if let generated = created.1 {
                // Shown on its own screen, never in a field that reads like a password:
                // this value reproduces every password of the account without the key.
                backup = generated
                show(.backupKey(AccountRef(created.0)))
            } else {
                // An import has its backup already — the one that was just pasted.
                show(.accounts)
                if case .import = request {
                    setStatus("Account imported — it derives the same passwords as the original")
                } else {
                    setStatus("Account added")
                }
            }
        } catch {
            guard flowLease.isValid else { return }
            enrollStep = nil
            present(error)
        }
    }

    /// A fresh identity for the account being created — for someone who typed over the one
    /// offered and wants a random one back.
    func randomiseEnrollIdentity() {
        enrollDraft.randomiseIdentity()
    }

    static func stepMessage(_ step: PortableEnrollmentStep) -> String {
        switch step {
        case .creatingCredential: return "Step 1 of 2 — touch your key to create the credential"
        case .derivingBackupKey:  return "Step 2 of 2 — touch your key again to derive its backup key"
        case .savingRecord:       return "Saving the record to the key…"
        }
    }

    static func stepMessage(_ step: MigrationStep) -> String {
        switch step {
        case .readingOldAccount:    return "Step 1 of 4 — touch your key to read the old record"
        case .creatingCredential:   return "Step 2 of 4 — touch your key to create the new record"
        case .derivingNewComponent: return "Step 3 of 4 — touch your key to seal the new record"
        case .savingRecord:         return "Saving the record to the key…"
        case .verifying:            return "Step 4 of 4 — touch your key to verify the new record"
        case .deletingOld:          return "Verified. Deleting the old record…"
        case .rollingBack:          return "Something went wrong — removing the unfinished copy…"
        }
    }

    func deleteAccount(_ ref: AccountRef) async {
        guard !isWorking else { return }
        guard let account = accounts.account(ref) else { return }
        // Read before the account goes: the scope is its credential, which the account
        // carries and the store no longer has once it is deleted.
        let scope = labelTarget(for: ref)?.scope
        do {
            try await touchGate.withBusy("Deleting “\(ref.accountId)”…") {
                try await accounts.delete(account)
            }
            if let scope { labels.forget(scope) }
            generation.clearResult()
            if selection == ref { selection = nil }
            restoreSelectionIfNeeded()
            show(.accounts)
            setStatus("Account deleted")
        } catch {
            present(error)
        }
    }

    // MARK: - Migration

    /// Opens the migration screen for a v1 portable account. The identity is random, or —
    /// when an unfinished copy is already on the key — the copy's own, which is not for
    /// changing here.
    func beginMigration(_ ref: AccountRef) {
        guard let account = accounts.account(ref), isMigratable(account) else { return }
        if let copy = accounts.migrationCopy(for: ref), let identity = copy.account.identity {
            migrationDraft = MigrationDraft(identity: identity, isFixed: true)
        } else {
            migrationDraft = MigrationDraft()
        }
        selection = ref
        show(.migrate(ref))
    }

    /// The unfinished copy of the account the migration screen is about, if there is one.
    var migrationCopy: AccountHandle? {
        guard case .migrate(let ref) = route else { return nil }
        return accounts.migrationCopy(for: ref)
    }

    /// Recreates the account as v2 — or finishes the copy already on the key. Four touches
    /// the first time, two to finish; the old record goes only after the new one has been
    /// read back and verified, so a failure leaves every password where it was.
    func migrate() async {
        guard !isWorking else { return }
        guard case .migrate(let ref) = route,
              let account = accounts.account(ref),
              isMigratable(account),
              let identity = migrationDraft.identity else { return }
        // The history follows the account: the migrated one is a new credential, and the
        // labels are the one thing about the old one that cannot be derived again.
        let oldScope = labelTarget(for: ref)?.scope
        let finishing = accounts.migrationCopy(for: ref) != nil
        let flowLease = accountFlowLease
        do {
            let migrated = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                                 message: finishing
                                                                     ? "Two touches: read the old record, verify the new one."
                                                                     : "Four touches. The old record is deleted only after the new one is verified.",
                                                                 deviceName: selectedDevice?.displayName ?? "Security key")) {
                let promptLease = KeyOperationContext.lease
                let report: @Sendable (MigrationStep) -> Void = { step in
                    Task { @MainActor in
                        guard flowLease.isValid else { return }
                        self.touchGate.updatePrompt(message: Self.stepMessage(step), ownedBy: promptLease)
                    }
                }
                return finishing
                    ? try await self.accounts.finishMigration(account, onStep: report)
                    : try await self.accounts.migrate(account, identity: identity, onStep: report)
            }
            if let oldScope {
                labels.move(from: oldScope, to: LabelScope(credentialId: migrated.credentialIdB64))
            }
            select(AccountRef(migrated))
            show(.accounts)
            setStatus("Account migrated — passwords are unchanged")
        } catch {
            present(error)
        }
    }

    /// Deletes the unfinished copy and leaves the original as it was. PIN, no touch.
    func discardMigrationCopy() async {
        guard !isWorking else { return }
        guard case .migrate(let ref) = route, let account = accounts.account(ref) else { return }
        do {
            try await touchGate.withBusy("Removing the unfinished copy of “\(ref.accountId)”…") {
                try await accounts.discardMigrationCopy(of: account)
            }
            migrationDraft = MigrationDraft()
            setStatus("Unfinished copy removed — the account is as it was")
        } catch {
            present(error)
        }
    }

    /// The identity is not a secret: no timeout, no receipt, but the same concealed path as
    /// everything else the app puts on the clipboard.
    func copyIdentity(for ref: AccountRef) {
        guard let identity = accounts.account(ref)?.account.identity else { return }
        generation.copyIdentity(identity)
        setStatus("Identity copied")
    }

    // MARK: - Backup key and recovery

    /// Works for an account from before identities too: it exports what it always did, the
    /// master key alone, and the screen says so. Export must not wait for migration — a
    /// backup is the last thing that should be gated.
    func showBackupKey(for ref: AccountRef) async {
        guard !isWorking else { return }
        guard let account = accounts.account(ref), account.kind == .portable else { return }
        if let problem = account.account.integrity.problem {
            error = .plain(problem)
            return
        }
        do {
            let exported = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                                 message: "Recovering the backup key.",
                                                                 deviceName: selectedDevice?.displayName ?? "Security key")) {
                try await self.accounts.exportBackup(for: account)
            }
            backup = exported
            show(.backupKey(ref))
        } catch {
            present(error)
        }
    }

    func copyBackupKey() {
        guard let backup, case .backupKey(let ref) = route else { return }
        guard generation.copy(backup.base64, as: .backupKey, for: ref) else {
            error = .plain("Could not write to the clipboard.")
            return
        }
        error = nil
    }

    func saveRecoverySheet(for ref: AccountRef) {
        guard !isShowingSystemPanel else { return }
        guard let account = accounts.account(ref) else { return }
        let description = devices.state(for: ref.devicePath).map { "\($0.device.displayName) — \($0.device.identityLabel)" }
        let known = labelTarget(for: ref).map { labels.labels(for: $0.scope) } ?? []
        let sheet = RecoverySheet(account: account.account,
                                  parameters: .v1,
                                  labels: known,
                                  deviceDescription: description)
        isShowingSystemPanel = true
        router.saveRecoverySheet(sheet)
    }

    func recoverySheetFinished(saved: Bool, failure: String? = nil) {
        isShowingSystemPanel = false
        if let failure {
            error = .plain("Could not save the recovery sheet: \(failure)")
        } else if saved {
            setStatus("Recovery sheet saved — it contains no secrets")
        }
    }

}
