import Combine
import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

@MainActor
final class PanelStoreTests: XCTestCase {

    // MARK: - Unlock and the pending intent

    /// The zero-click path: the HUD is opened *in order to* copy something, the key turns
    /// out to be locked, and unlocking has to finish the job rather than drop the user on a
    /// list they then have to navigate again.
    func testUnlockingContinuesWhatTheUserAskedFor() async {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.accountsByPath[device.path] = [Account.fixture(id: "vault", kind: .portable)]

        let store = AppTestFactory.makeStore(backend: backend)
        let ref = AccountRef(accountId: "vault", devicePath: device.path)
        await store.prepareForDisplay(intent: .copyPassword(ref, label: "work"))

        XCTAssertEqual(store.route, .unlock, "a locked key must ask for the PIN first")
        XCTAssertNotNil(store.pendingSummary, "the PIN screen must say what it is unlocking for")

        store.pinDraft = "1234"
        await store.submitPin()

        XCTAssertEqual(backend.generateCalls.map(\.label), ["work"])
        XCTAssertEqual(store.generation.result?.password, backend.generatedPassword)
        XCTAssertEqual(store.route, .accounts)
    }

    func testWrongPinKeepsTheUserOnThePinScreenAndReportsAttempts() async {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.statusByPath[device.path] = DeviceStatus(pinRetriesRemaining: 3,
                                                         hasPIN: true,
                                                         supportsHmacSecret: true,
                                                         remainingResidentKeys: 10)

        let store = AppTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()
        store.pinDraft = "0000"
        await store.submitPin()

        XCTAssertEqual(store.route, .unlock)
        XCTAssertEqual(store.devices.state(for: device.path)?.pinRetriesRemaining, 3)
        XCTAssertTrue(store.pinDraft.isEmpty, "a failed attempt must not leave the PIN in the field")
        XCTAssertNotNil(store.error)
    }

    /// Nothing about a locked key may stay reachable: not its accounts, not a password it
    /// derived, not the selection that points at it.
    func testLockingDropsEverythingDerivedFromThatKey() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let ref = AccountRef(accountId: "vault", devicePath: device.path)
        await store.copyPassword(for: ref, label: "vault")
        XCTAssertNotNil(store.generation.result)

        store.lockSelectedKey()

        XCTAssertTrue(store.accounts.accounts.isEmpty)
        XCTAssertNil(store.generation.result)
        XCTAssertNil(store.selection)
        XCTAssertEqual(store.effectiveRoute, .unlock, "what the panel shows is derived from the key, not from a stored route")
    }

    /// Pressing Return used to leave the PIN form on screen while the key was being asked,
    /// which reads as "nothing happened, type it again" — and typing it again is precisely
    /// how PIN attempts get spent.
    func testVerifyingThePinShowsAWaitingStateInsteadOfTheFormAgain() async {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        let gate = BlockingGate()

        let store = AppTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()
        store.pinDraft = "1234"
        backend.enumerateGate = gate

        let submission = Task { await store.submitPin() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(store.isWorking)
        XCTAssertNotNil(store.busyTitle, "the panel must say it is checking, not re-offer the field")

        gate.open()
        await submission.value
        XCTAssertNil(store.busyTitle)
        XCTAssertFalse(store.isWorking)
    }

    /// One keypress must never spend two PIN attempts.
    ///
    /// Return can reach the store twice — the field's submit action and the screen's default
    /// button — and a FIDO2 key dies permanently after eight consecutive failures. This is
    /// the one place in the app where a duplicated call is not merely wasteful.
    func testOneKeypressCannotSpendTwoPinAttempts() async {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"

        let store = AppTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()
        let before = backend.enumerateCallCount
        store.pinDraft = "0000"

        async let first: Void = store.submitPin()
        async let second: Void = store.submitPin()
        _ = await (first, second)

        XCTAssertEqual(backend.enumerateCallCount - before, 1, "the second call must be refused while the first is in flight")
    }

    /// Same reasoning, cheaper stakes: a duplicated generate costs the user a second touch
    /// of the key for a password they already have.
    func testDuplicateGenerateRequestsCollapseIntoOne() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        let ref = AccountRef(accountId: "vault", devicePath: device.path)

        async let first: Void = store.copyPassword(for: ref, label: "vault")
        async let second: Void = store.copyPassword(for: ref, label: "vault")
        _ = await (first, second)

        XCTAssertEqual(backend.generateCalls.count, 1)
    }

    // MARK: - Generation

    func testGeneratingRaisesTheTouchPromptAndRemembersTheChoice() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        let ref = AccountRef(accountId: "vault", devicePath: device.path)

        var sawPrompt = false
        let watching = store.touchGate.$prompt.sink { if $0 != nil { sawPrompt = true } }
        await store.copyPassword(for: ref, label: "work")
        watching.cancel()

        XCTAssertTrue(sawPrompt, "an operation that makes the key wait for a finger must say so")
        XCTAssertNil(store.touch, "and the prompt must come down afterwards")
        XCTAssertEqual(backend.generateCalls.count, 1)
        XCTAssertEqual(store.preferences.lastUsed?.accountId, "vault")
        XCTAssertEqual(store.preferences.lastUsed?.label, "work")
        XCTAssertEqual(store.labels.recent.first, "work")
        XCTAssertEqual(store.labels.labels(for: store.labelTarget(for: ref)!.scope), ["work"],
                       "recorded against the account it was derived for")
        XCTAssertEqual(store.labels.labels(for: store.labelTarget(for: AccountRef(accountId: "disk", devicePath: device.path))!.scope), [],
                       "and against that one only — the same label is a different password elsewhere")
    }

    func testCopiedPasswordIsRecordedAgainstItsOwnAccount() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let vault = AccountRef(accountId: "vault", devicePath: device.path)
        await store.copyPassword(for: vault, label: "vault")

        XCTAssertEqual(store.generation.receipt?.ref, vault)
        XCTAssertEqual(store.generation.receipt?.item, .password)
        XCTAssertEqual(store.iconState, .clipboardHot, "the menu-bar icon is what says a secret is still out there")
    }

    /// Revealing is the alternative to copying, not an extra step after it.
    func testRevealDoesNotTouchTheClipboard() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        await store.revealPassword(for: AccountRef(accountId: "vault", devicePath: device.path), label: "vault")

        XCTAssertEqual(store.generation.result?.revealed, true)
        XCTAssertNil(store.generation.receipt)
    }

    /// Editing the label used to leave the previous password on screen, so copying handed
    /// over a secret derived from something else entirely.
    func testChangingTheLabelDropsAStaleResult() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let ref = AccountRef(accountId: "vault", devicePath: device.path)
        await store.copyPassword(for: ref, label: "vault")
        XCTAssertNotNil(store.generation.result)

        store.setLabel("something-else")
        XCTAssertNil(store.generation.result)
    }

    func testSwitchingAccountsDropsTheResult() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        await store.copyPassword(for: AccountRef(accountId: "vault", devicePath: device.path), label: "vault")
        XCTAssertNotNil(store.generation.result)

        store.select(AccountRef(accountId: "disk", devicePath: device.path))
        XCTAssertNil(store.generation.result, "a result must not follow the user to another account")
    }

    // MARK: - Enrolment

    func testPortableEnrolmentEndsOnTheBackupKeyScreen() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        store.enrollDraft.accountId = "  backup  "
        store.enrollDraft.mode = .portable
        await store.createAccount()

        XCTAssertEqual(backend.enrollCalls.last?.accountId, "backup", "the id must be trimmed before it reaches the key")
        XCTAssertNil(backend.enrollCalls.last?.imported)
        let ref = AccountRef(accountId: "backup", devicePath: device.path)
        XCTAssertEqual(store.route, .backupKey(ref), "a freshly created backup key has to be shown once, immediately")
        XCTAssertEqual(store.backup, backend.backupValue)
        XCTAssertEqual(store.backup?.base64.count, 60)
        XCTAssertEqual(store.accounts.account(ref)?.account.identity, store.backup?.identity,
                       "the backup carries the identity the new account shows")
    }

    func testLocalEnrolmentProducesNoBackupKey() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        store.enrollDraft.accountId = "disk-2"
        store.enrollDraft.mode = .local
        await store.createAccount()

        XCTAssertEqual(store.route, .accounts)
        XCTAssertNil(store.backup)
    }

    /// Anything but a whole backup would derive different passwords, silently.
    func testImportRequiresAWholeBackup() {
        var draft = EnrollDraft()
        draft.accountId = "vault"
        draft.mode = .import
        XCTAssertFalse(draft.canCreate, "nothing pasted yet")
        XCTAssertNil(draft.importError, "an empty field is not an error")

        draft.importText = "not-base64"
        XCTAssertNotNil(draft.importError)
        XCTAssertFalse(draft.canCreate)

        draft.importText = Data(repeating: 7, count: 16).base64EncodedString()
        XCTAssertNotNil(draft.importError, "a short key would derive different passwords, silently")

        let current = PortableBackup(masterKey: Data(repeating: 7, count: 32),
                                     identity: AccountIdentity(hex: "070707070707070707070707"))!
        draft.importText = " " + current.base64 + "\n"
        XCTAssertNil(draft.importError)
        XCTAssertTrue(draft.canCreate)
        XCTAssertEqual(draft.request, .import(current))

        // A backup from before identities parses, but is not complete until it has one.
        draft.importText = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertNil(draft.importError)
        XCTAssertTrue(draft.importIsLegacy)
        XCTAssertFalse(draft.canCreate)
        draft.legacyIdentityHex = "not hex"
        XCTAssertNotNil(draft.legacyIdentityError)
        XCTAssertFalse(draft.canCreate)
        draft.legacyIdentityHex = "0102 0304 0506 0708 090a 0b0c"
        XCTAssertNil(draft.legacyIdentityError)
        XCTAssertTrue(draft.canCreate)
        XCTAssertEqual(draft.parsedImport?.identity, AccountIdentity(hex: "0102030405060708090a0b0c"))
        XCTAssertEqual(draft.parsedImport?.masterKey, Data(repeating: 7, count: 32))

        // Local and portable ignore whatever is left in the import field.
        draft.mode = .local
        draft.importText = "garbage"
        XCTAssertNil(draft.importError)
        XCTAssertTrue(draft.canCreate)
        XCTAssertEqual(draft.request, .local)
    }

    /// An import already has its backup — the one that was just pasted — so it ends on the
    /// list, and the new account shows the identity the backup carried.
    func testImportEndsOnTheAccountList() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        let backup = PortableBackup(masterKey: Data(repeating: 9, count: 32),
                                    identity: AccountIdentity(hex: "090909090909090909090909"))!
        store.enrollDraft.accountId = "copy"
        store.enrollDraft.mode = .import
        store.enrollDraft.importText = backup.base64
        await store.createAccount()

        XCTAssertEqual(backend.enrollCalls.last?.imported, backup)
        XCTAssertEqual(store.route, .accounts)
        XCTAssertNil(store.backup)
        let ref = AccountRef(accountId: "copy", devicePath: device.path)
        XCTAssertEqual(store.selection, ref)
        XCTAssertEqual(store.accounts.account(ref)?.account.identity, backup.identity)
    }

    /// A backup printed before identities existed gets one on import: random unless the
    /// user types the one the account shows elsewhere.
    func testImportingALegacyBackupTakesAnIdentity() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        store.enrollDraft.accountId = "old"
        store.enrollDraft.mode = .import
        store.enrollDraft.importText = Data(repeating: 3, count: 32).base64EncodedString()

        XCTAssertTrue(store.enrollDraft.importIsLegacy)
        XCTAssertNotNil(store.enrollDraft.legacyIdentity, "a random identity is offered the moment a legacy backup is recognised")
        XCTAssertTrue(store.enrollDraft.canCreate)

        let chosen = AccountIdentity(hex: "0c0b0a090807060504030201")!
        store.enrollDraft.legacyIdentityHex = chosen.groupedHex
        await store.createAccount()

        XCTAssertEqual(backend.enrollCalls.last?.imported?.masterKey, Data(repeating: 3, count: 32))
        XCTAssertEqual(backend.enrollCalls.last?.imported?.identity, chosen)
        XCTAssertEqual(store.route, .accounts)
    }

    /// The list shows the identity beside every account: stored for a portable one, derived
    /// for a local one. Nothing on the key is read for the second.
    func testEveryAccountHasAnIdentity() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        for handle in store.visibleAccounts {
            XCTAssertNotNil(handle.account.identity, handle.id)
            XCTAssertFalse(handle.account.needsMigration, handle.id)
        }
    }

    // MARK: - Migration

    /// A key holding one account from before identities and one local account.
    private static func legacyStore() async -> (PanelStore, MockKeyBackend, FidoDevice, AccountRef) {
        let (store, backend, device) = await AppTestFactory.unlockedStore(accounts: [
            Account.portableFixture(id: "old", legacy: true),
            Account.fixture(id: "disk", kind: .local)
        ])
        return (store, backend, device, AccountRef(accountId: "old", devicePath: device.path))
    }

    /// Nothing is derived from an account until it has an identity: asking for a password
    /// lands on the migration screen, and the key is not touched.
    func testALegacyAccountRoutesToMigrationInsteadOfGenerating() async {
        let (store, backend, _, old) = await Self.legacyStore()
        await store.copyPassword(for: old, label: "vault")

        XCTAssertEqual(store.route, .migrate(old))
        XCTAssertEqual(store.selection, old)
        XCTAssertTrue(backend.generateCalls.isEmpty, "nothing is derived before the identity exists")
        XCTAssertNil(store.generation.result)
        XCTAssertNotNil(store.migrationDraft.identity, "a random identity is offered")
    }

    func testEncryptingWithALegacyAccountRoutesToMigration() async {
        let (store, _, _, old) = await Self.legacyStore()
        store.setLabel("notes")
        await store.openEncryptEditor(for: old)

        XCTAssertEqual(store.route, .migrate(old))
        let router = AppTestFactory.container(for: store).router as? RecordingWindowRouter
        XCTAssertEqual(router?.openedEditors.count, 0, "no editor opens on an account without an identity")
    }

    /// Rule 7 on real store state: with a legacy account selected, `⏎` migrates; with the
    /// local one selected, it generates as ever.
    func testPrimaryActionForALegacySelectionIsMigrate() async {
        let (store, _, _, old) = await Self.legacyStore()
        store.select(old)
        XCTAssertEqual(store.primaryAction, .migrate(old))

        let disk = AccountRef(accountId: "disk", devicePath: old.devicePath)
        store.select(disk)
        XCTAssertEqual(store.primaryAction, .generateAndCopy(disk))
    }

    func testMigrationRewritesTheAccountAndUnlocksGeneration() async {
        let (store, backend, _, old) = await Self.legacyStore()
        store.beginMigration(old)
        XCTAssertEqual(store.route, .migrate(old))

        let chosen = AccountIdentity(hex: "0102030405060708090a0b0c")!
        store.migrationDraft.identityHex = chosen.groupedHex
        await store.migrate()

        XCTAssertEqual(backend.assignIdentityCalls.count, 1)
        XCTAssertEqual(backend.assignIdentityCalls.first?.identity, chosen)
        XCTAssertEqual(store.route, .accounts)
        XCTAssertNotNil(store.statusText)

        let migrated = store.accounts.account(old)
        XCTAssertEqual(migrated?.account.identity, chosen)
        XCTAssertEqual(migrated?.account.needsMigration, false)
        XCTAssertEqual(store.primaryAction, .generateAndCopy(old), "once migrated, ⏎ generates again")

        await store.copyPassword(for: old, label: "vault")
        XCTAssertEqual(backend.generateCalls.map { $0.accountId }, ["old"])
        XCTAssertEqual(store.route, .accounts)
        XCTAssertNotNil(store.generation.result)
    }

    func testMigrationDraftValidatesHex() {
        var draft = MigrationDraft()
        XCTAssertNotNil(draft.identity, "opens with a random identity")
        XCTAssertNil(draft.error)

        draft.identityHex = "zz"
        XCTAssertNil(draft.identity)
        XCTAssertNotNil(draft.error)

        draft.identityHex = ""
        XCTAssertNil(draft.identity)
        XCTAssertNil(draft.error, "an empty field is not an error, just incomplete")

        draft.identityHex = "0102-0304-0506-0708-090A-0B0C"
        XCTAssertEqual(draft.identity, AccountIdentity(hex: "0102030405060708090a0b0c"))

        let before = draft.identityHex
        draft.randomise()
        XCTAssertNotEqual(draft.identityHex, before)
        XCTAssertNotNil(draft.identity)
    }

    func testMigrateWithAnInvalidIdentityDoesNothing() async {
        let (store, backend, _, old) = await Self.legacyStore()
        store.beginMigration(old)
        store.migrationDraft.identityHex = "not hex"
        await store.migrate()

        XCTAssertTrue(backend.assignIdentityCalls.isEmpty)
        XCTAssertEqual(store.route, .migrate(old))
    }

    func testARefusedMigrationStaysOnTheScreenWithTheError() async {
        let (store, backend, _, old) = await Self.legacyStore()
        backend.assignIdentityError = TestError.generic("refused")
        store.beginMigration(old)
        await store.migrate()

        XCTAssertEqual(store.route, .migrate(old))
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.accounts.account(old)?.account.needsMigration, true)
    }

    /// Export is the one thing that does not wait for migration: a legacy account hands out
    /// its backup in the format earlier versions printed, and the screen says so.
    func testBackupKeyOfALegacyAccountIsTheLegacyFormat() async {
        let (store, backend, _, old) = await Self.legacyStore()
        await store.showBackupKey(for: old)

        XCTAssertEqual(backend.exportCalls, ["old"])
        XCTAssertEqual(store.route, .backupKey(old), "not the migration screen")
        XCTAssertEqual(store.backup?.isLegacy, true)
        XCTAssertEqual(store.backup?.base64.count, 44)
    }

    func testMigrationScreenHoldsThePanelAndEscapesToTheList() async {
        let (store, _, _, old) = await Self.legacyStore()
        store.beginMigration(old)
        XCTAssertTrue(store.isPinnedOpen)
        XCTAssertEqual(store.keyboardHints, ["⏎ migrate", "esc cancel"])
        XCTAssertTrue(store.handleEscape())
        XCTAssertEqual(store.route, .accounts)
    }

    func testBeginMigrationIgnoresAccountsThatDoNotNeedIt() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        store.beginMigration(AccountRef(accountId: "vault", devicePath: device.path))
        XCTAssertEqual(store.route, .accounts)
    }

    /// The identity goes on the clipboard through the concealed path, without a receipt: it
    /// is not a secret, and a countdown for it would be noise.
    func testCopyingTheIdentityLeavesNoReceipt() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        store.copyIdentity(for: AccountRef(accountId: "vault", devicePath: device.path))
        XCTAssertNil(store.generation.receipt)
        XCTAssertEqual(store.statusText, "Identity copied")
    }

    func testDeletingRemovesTheAccountFromTheList() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        await store.deleteAccount(AccountRef(accountId: "disk", devicePath: device.path))

        XCTAssertEqual(backend.deleteCalls, ["disk"])
        XCTAssertFalse(store.accounts.accounts.contains { $0.id == "disk" })
        XCTAssertEqual(store.route, .accounts)
    }

    /// Deleting an account takes its labels with it: nothing may be left pointing at a
    /// credential that no longer exists.
    func testDeletingAnAccountForgetsItsLabels() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let ref = AccountRef(accountId: "disk", devicePath: device.path)
        let scope = store.labelTarget(for: ref)!.scope
        await store.copyPassword(for: ref, label: "disk-label")
        XCTAssertEqual(store.labels.labels(for: scope), ["disk-label"])

        await store.deleteAccount(ref)
        XCTAssertEqual(store.labels.labels(for: scope), [])
    }

    /// Shortening the timeout is something a user does because they want the key to lock
    /// sooner — including the key that is unlocked right now.
    func testChangingTheLockTimeoutAppliesToTheKeyAlreadyUnlocked() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        XCTAssertEqual(store.devices.pinTTL, 300)

        store.preferences.lockTimeout = 60
        XCTAssertEqual(store.devices.pinTTL, 60)
    }

    /// The click budget, checked against a real store rather than a hand-built snapshot:
    /// with a key unlocked and an account preselected, the daily action is "copy this
    /// password", never "now choose an account".
    func testThePrimaryActionOfAnUnlockedKeyIsToCopy() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        XCTAssertEqual(store.primaryAction, .generateAndCopy(store.selection!))

        store.lockSelectedKey()
        XCTAssertEqual(store.primaryAction, .unlock(devicePath: device.path))
    }

    /// The same budget for a key that has never been used: with no PIN on it, the one thing
    /// worth doing is giving it one — not offering a field no PIN can satisfy.
    func testThePrimaryActionOfAKeyWithoutAPinIsToSetOne() async {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.statusByPath[device.path] = DeviceStatus(pinRetriesRemaining: nil,
                                                         hasPIN: false,
                                                         supportsHmacSecret: true,
                                                         remainingResidentKeys: 25)
        let store = AppTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()

        XCTAssertEqual(store.primaryAction, .setPIN(devicePath: device.path))
    }

    // MARK: - Labels

    /// The chips have to follow the account. A label belonging to another one derives a
    /// password that is perfectly valid and perfectly wrong.
    func testSelectingAnAccountSwitchesItsLabelHistory() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let vault = AccountRef(accountId: "vault", devicePath: device.path)
        let disk = AccountRef(accountId: "disk", devicePath: device.path)
        await store.copyPassword(for: vault, label: "vault-label")
        await store.copyPassword(for: disk, label: "disk-label")

        store.select(vault)
        XCTAssertEqual(store.labels.recent, ["vault-label"])
        XCTAssertEqual(store.labelEditor.current, "vault-label", "and the HUD opens on the one used here last")

        store.select(disk)
        XCTAssertEqual(store.labels.recent, ["disk-label"])
        XCTAssertFalse(store.labels.chips.contains("vault-label"))
    }

    /// The sheet's whole purpose is to record what cannot be derived again — and it says
    /// "labels used with this account", so it has to be true.
    func testRecoverySheetCarriesOnlyThisAccountsLabels() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let vault = AccountRef(accountId: "vault", devicePath: device.path)
        await store.copyPassword(for: vault, label: "vault-label")
        await store.copyPassword(for: AccountRef(accountId: "disk", devicePath: device.path), label: "disk-label")

        store.saveRecoverySheet(for: vault)

        let router = store.router as? RecordingWindowRouter
        XCTAssertEqual(router?.savedSheets.last?.labels, ["vault-label"])
    }

    // MARK: - Keyboard navigation

    func testArrowsMoveBetweenAccounts() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        store.select(AccountRef(accountId: "disk", devicePath: device.path))

        store.moveSelection(by: -1)
        XCTAssertEqual(store.selection?.accountId, "disk", "first account: nothing above it")

        store.moveSelection(by: 1)
        XCTAssertEqual(store.selection?.accountId, "vault")

        // Clamped rather than wrapping: with two accounts, jumping from the last back to the
        // first is a way to derive the wrong password without noticing.
        store.moveSelection(by: 1)
        XCTAssertEqual(store.selection?.accountId, "vault")
    }

    /// The arrows walk the whole row — chips first, then the custom field, which is a
    /// position like any other rather than a dead end past the last chip. The row is a ring:
    /// with three or four positions, a key that does nothing at the edge is just a dead key.
    func testArrowsWalkTheChipsAndTheCustomFieldInARing() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        AppTestFactory.seedLabels(store, ["work", "vault"])   // chips: ["vault", "work"]
        let chips = store.labels.chips
        XCTAssertEqual(chips.count, 2)

        store.labelEditor.moveFocus(by: 1)
        XCTAssertEqual(store.labelEditor.current, chips[1])
        XCTAssertFalse(store.labelEditor.isEditing)

        store.labelEditor.moveFocus(by: 1)
        XCTAssertTrue(store.labelEditor.isEditing, "past the last chip lies the custom field")

        store.labelEditor.moveFocus(by: 1)
        XCTAssertFalse(store.labelEditor.isEditing)
        XCTAssertEqual(store.labelEditor.current, chips[0], "and past the field, back to the first chip")

        store.labelEditor.moveFocus(by: -1)
        XCTAssertTrue(store.labelEditor.isEditing, "left from the first chip wraps onto the field")
        XCTAssertTrue(store.labelEditor.caretAtEnd, "arriving from the right, the caret waits at the end")

        store.labelEditor.moveFocus(by: -1)
        XCTAssertFalse(store.labelEditor.isEditing)
        XCTAssertEqual(store.labelEditor.current, chips.last)
    }

    /// A label typed by hand is the field's position, even before the field has focus.
    func testACustomLabelCountsAsBeingAtTheField() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        AppTestFactory.seedLabels(store, ["work"])
        store.setLabel("something-new")
        XCTAssertFalse(store.labelEditor.isEditing)

        store.labelEditor.moveFocus(by: -1)
        XCTAssertEqual(store.labelEditor.current, "work", "left steps back onto the last chip")

        store.labelEditor.moveFocus(by: 1)
        XCTAssertTrue(store.labelEditor.isEditing, "and right returns to the field holding that text")
    }

    /// Switching label must drop a password derived from the previous one, exactly as
    /// clicking a chip does — the keyboard is not a second, sloppier path.
    func testMovingBetweenLabelsDropsAStaleResult() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        AppTestFactory.seedLabels(store, ["work", "archive"])   // two choices, or there is nothing to cycle between
        await store.copyPassword(for: store.selection)
        XCTAssertNotNil(store.generation.result)

        // Right, not left: the copy used the first chip, and there is nothing to its left.
        store.labelEditor.moveFocus(by: 1)
        XCTAssertNil(store.generation.result)
    }

    /// A shortcut nobody knows about is the same as one that does not exist.
    func testHintsNameTheNonObviousShortcuts() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        XCTAssertTrue(store.keyboardHints.contains("⏎ copy"))
        XCTAssertTrue(store.keyboardHints.contains("↑↓ account"))

        store.lockSelectedKey()
        XCTAssertEqual(store.keyboardHints, ["⏎ unlock"])
    }

    /// One account, one label: no arrows are advertised, because there is nowhere to go.
    func testHintsOmitArrowsWhenThereIsNothingToMoveBetween() async {
        let device = MockKeyBackend.device()
        let single = [Account.fixture(id: "vault", kind: .portable)]
        let (store, _, _) = await AppTestFactory.unlockedStore(accounts: single)

        XCTAssertFalse(store.keyboardHints.contains("↑↓ account"))
    }

    /// Escape on a pushed screen goes back; only at the top level does it close the panel.
    func testEscapeLeavesTheScreenBeforeItLeavesTheApp() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        store.show(.confirmDelete(AccountRef(accountId: "vault", devicePath: device.path)))

        XCTAssertTrue(store.handleEscape())
        XCTAssertEqual(store.effectiveRoute, .accounts)
        XCTAssertFalse(store.handleEscape(), "at the top level the panel itself should close")
    }

    // MARK: - What the panel is allowed to show

    /// The panel is drawn as soon as it opens, before the refresh behind it finishes. A
    /// stale route used to paint "No accounts on this key" — with a Create button — under a
    /// header reading "Locked". The account list of a locked key is unread, not empty.
    func testALockedKeyAlwaysShowsThePinScreen() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        store.lockSelectedKey()
        store.show(.accounts)

        XCTAssertEqual(store.effectiveRoute, .unlock)
    }

    /// ⌘N while the key is locked: unlock first, then land on the screen that was asked for.
    func testAScreenRequestedWhileLockedSurvivesUnlocking() async {
        let (store, _, _) = await AppTestFactory.unlockedStore()
        store.lockSelectedKey()
        store.show(.enroll)
        XCTAssertEqual(store.effectiveRoute, .unlock)

        store.pinDraft = "1234"
        await store.submitPin()

        XCTAssertEqual(store.effectiveRoute, .enroll)
    }

    // MARK: - Panel behaviour

    /// Screens the user is reading or typing into must not vanish when focus moves.
    func testReadingScreensHoldThePanelOpen() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        XCTAssertFalse(store.isPinnedOpen)

        store.show(.backupKey(AccountRef(accountId: "vault", devicePath: device.path)))
        XCTAssertTrue(store.isPinnedOpen)

        store.backToAccounts()
        XCTAssertFalse(store.isPinnedOpen)
    }

    /// A key that cannot be read looks exactly like a key with nothing on it. Saying which
    /// one it is matters most for the person whose accounts have just "disappeared".
    func testAnUnreadableKeyExplainsItselfInsteadOfLookingEmpty() async {
        let (store, backend, _) = await AppTestFactory.unlockedStore()
        backend.enumerateError = TestError.generic("Key is busy")

        await store.refresh()

        XCTAssertTrue(store.accounts.accounts.isEmpty)
        XCTAssertNotNil(store.error, "an empty list with no explanation is the worst of both")
    }

    /// The bug that made the HUD hang on "no security key connected" after one successful
    /// generation: enumeration failed for a moment, and the failure was read as "the desk is
    /// empty" — releasing the PIN token and every account of a key that never moved.
    func testEnumerationFailureDoesNotLookLikeAnUnpluggedKey() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        XCTAssertFalse(store.devices.devices.isEmpty)

        backend.listDevicesError = TestError.generic("device busy")
        await store.refresh()

        XCTAssertEqual(store.devices.devices.map(\.path), [device.path], "the key must survive a failed read")
        XCTAssertTrue(store.isSelectedKeyUnlocked, "and so must its unlocked state")
        XCTAssertFalse(store.accounts.accounts.isEmpty)
        XCTAssertNotNil(store.error, "but the user has to be told the read failed")
    }

    /// A key re-enumerates on the HID bus right after it is touched, so a single empty read
    /// in that window is noise rather than an unplug.
    func testOneEmptyReadAfterATouchIsNotAnUnplug() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        backend.listDevicesResults = [[], [device]]

        await store.refresh()

        XCTAssertEqual(store.devices.devices.map(\.path), [device.path])
        XCTAssertTrue(store.isSelectedKeyUnlocked)
    }

    func testUnpluggingAKeyClearsItsState() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        await store.copyPassword(for: AccountRef(accountId: "vault", devicePath: device.path), label: "vault")

        backend.devices = []
        await store.refresh()   // two empty reads in a row: really gone

        XCTAssertTrue(store.accounts.accounts.isEmpty)
        XCTAssertNil(store.generation.result)
        XCTAssertEqual(store.iconState, .noKey)
    }
}

/// The editor holds a derived key for as long as its window is open, so every path that
/// revokes access to an account has to take that window with it — otherwise "locked"
/// describes the account list while the secrets stay reachable elsewhere.
@MainActor
final class PanelEditorLifetimeTests: XCTestCase {

    func testLockingTheKeyClosesTheEditor() async {
        let (store, _, device) = await AppTestFactory.unlockedStore()
        let router = store.router as! RecordingWindowRouter

        await store.openEncryptEditor(for: AccountRef(accountId: "vault", devicePath: device.path))
        XCTAssertEqual(store.editor.boundDevicePath, device.path)
        XCTAssertEqual(router.openedEditors.count, 1)

        store.lockSelectedKey()
        XCTAssertEqual(router.editorClosed, 1, "locking must not leave a live key in an open window")
        XCTAssertNil(store.editor.boundDevicePath)
    }

    func testUnpluggingTheKeyClosesTheEditor() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        let router = store.router as! RecordingWindowRouter
        await store.openEncryptEditor(for: AccountRef(accountId: "vault", devicePath: device.path))

        backend.devices = []
        await store.refresh()
        XCTAssertEqual(router.editorClosed, 1)
    }

    func testAnEmptyLabelIsRefusedBeforeTheKeyIsTouched() async {
        let (store, backend, device) = await AppTestFactory.unlockedStore()
        store.setLabel("   ")
        await store.openEncryptEditor(for: AccountRef(accountId: "vault", devicePath: device.path))

        XCTAssertNotNil(store.error)
        XCTAssertNil(store.editor.boundDevicePath)
        XCTAssertTrue(backend.generateCalls.isEmpty)
    }
}
