import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassApp

@MainActor
final class HUDStoreTests: XCTestCase {

    // MARK: - Unlock and the pending intent

    /// The zero-click path: the HUD is opened *in order to* copy something, the key turns
    /// out to be locked, and unlocking has to finish the job rather than drop the user on a
    /// list they then have to navigate again.
    func testUnlockingContinuesWhatTheUserAskedFor() async {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.accountsByPath[device.path] = [Account.fixture(id: "vault", kind: .portable, devicePath: device.path)]

        let store = HUDTestFactory.makeStore(backend: backend)
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

        let store = HUDTestFactory.makeStore(backend: backend)
        await store.prepareForDisplay()
        store.pinDraft = "0000"
        await store.submitPin()

        XCTAssertEqual(store.route, .unlock)
        XCTAssertEqual(store.devices.state(for: device.path)?.pinRetriesRemaining, 3)
        XCTAssertTrue(store.pinDraft.isEmpty, "a failed attempt must not leave the PIN in the field")
        XCTAssertNotNil(store.errorText)
    }

    /// Nothing about a locked key may stay reachable: not its accounts, not a password it
    /// derived, not the selection that points at it.
    func testLockingDropsEverythingDerivedFromThatKey() async {
        let (store, _, device) = await HUDTestFactory.unlockedStore()
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

        let store = HUDTestFactory.makeStore(backend: backend)
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

        let store = HUDTestFactory.makeStore(backend: backend)
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
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        let ref = AccountRef(accountId: "vault", devicePath: device.path)

        async let first: Void = store.copyPassword(for: ref, label: "vault")
        async let second: Void = store.copyPassword(for: ref, label: "vault")
        _ = await (first, second)

        XCTAssertEqual(backend.generateCalls.count, 1)
    }

    // MARK: - Generation

    func testGeneratingRaisesTheTouchPromptAndRemembersTheChoice() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        let ref = AccountRef(accountId: "vault", devicePath: device.path)

        var sawPrompt = false
        store.onStateChanged = { if store.touch != nil { sawPrompt = true } }
        await store.copyPassword(for: ref, label: "work")

        XCTAssertTrue(sawPrompt, "an operation that makes the key wait for a finger must say so")
        XCTAssertNil(store.touch, "and the prompt must come down afterwards")
        XCTAssertEqual(backend.generateCalls.count, 1)
        XCTAssertEqual(store.preferences.lastUsed?.accountId, "vault")
        XCTAssertEqual(store.preferences.lastUsed?.label, "work")
        XCTAssertEqual(store.labels.recent.first, "work")
    }

    func testCopiedPasswordIsRecordedAgainstItsOwnAccount() async {
        let (store, _, device) = await HUDTestFactory.unlockedStore()
        let vault = AccountRef(accountId: "vault", devicePath: device.path)
        await store.copyPassword(for: vault, label: "vault")

        XCTAssertEqual(store.generation.receipt?.ref, vault)
        XCTAssertEqual(store.generation.receipt?.item, .password)
        XCTAssertEqual(store.iconState, .clipboardHot, "the menu-bar icon is what says a secret is still out there")
    }

    /// Revealing is the alternative to copying, not an extra step after it.
    func testRevealDoesNotTouchTheClipboard() async {
        let (store, _, device) = await HUDTestFactory.unlockedStore()
        await store.revealPassword(for: AccountRef(accountId: "vault", devicePath: device.path), label: "vault")

        XCTAssertEqual(store.generation.result?.revealed, true)
        XCTAssertNil(store.generation.receipt)
    }

    /// Editing the label used to leave the previous password on screen, so copying handed
    /// over a secret derived from something else entirely.
    func testChangingTheLabelDropsAStaleResult() async {
        let (store, _, device) = await HUDTestFactory.unlockedStore()
        let ref = AccountRef(accountId: "vault", devicePath: device.path)
        await store.copyPassword(for: ref, label: "vault")
        XCTAssertNotNil(store.generation.result)

        store.setLabel("something-else")
        XCTAssertNil(store.generation.result)
    }

    func testSwitchingAccountsDropsTheResult() async {
        let (store, _, device) = await HUDTestFactory.unlockedStore()
        await store.copyPassword(for: AccountRef(accountId: "vault", devicePath: device.path), label: "vault")
        XCTAssertNotNil(store.generation.result)

        store.select(AccountRef(accountId: "disk", devicePath: device.path))
        XCTAssertNil(store.generation.result, "a result must not follow the user to another account")
    }

    // MARK: - Enrolment

    func testPortableEnrolmentEndsOnTheBackupKeyScreen() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        store.enrollDraft.accountId = "  backup  "
        store.enrollDraft.kind = .portable
        await store.createAccount()

        XCTAssertEqual(backend.enrollCalls.last?.accountId, "backup", "the id must be trimmed before it reaches the key")
        XCTAssertEqual(store.route, .backupKey(AccountRef(accountId: "backup", devicePath: device.path)),
                       "a freshly created backup key has to be shown once, immediately")
        XCTAssertEqual(store.backupKey, backend.backupKeyValue)
    }

    func testLocalEnrolmentProducesNoBackupKey() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        store.enrollDraft.accountId = "disk-2"
        store.enrollDraft.kind = .local
        await store.createAccount()

        XCTAssertEqual(store.route, .accounts)
        XCTAssertNil(store.backupKey)
    }

    func testImportedKeyMustBeThirtyTwoBytes() {
        var draft = HUDStore.EnrollDraft()
        draft.accountId = "vault"
        draft.importedKeyB64 = "not-base64"
        XCTAssertNotNil(draft.importedKeyError)
        XCTAssertFalse(draft.canCreate)

        draft.importedKeyB64 = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertNil(draft.importedKeyError)
        XCTAssertTrue(draft.canCreate)

        draft.importedKeyB64 = Data(repeating: 7, count: 16).base64EncodedString()
        XCTAssertNotNil(draft.importedKeyError, "a short key would derive different passwords, silently")
    }

    func testDeletingRemovesTheAccountFromTheList() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        await store.deleteAccount(AccountRef(accountId: "disk", devicePath: device.path))

        XCTAssertEqual(backend.deleteCalls, ["disk"])
        XCTAssertFalse(store.accounts.accounts.contains { $0.id == "disk" })
        XCTAssertEqual(store.route, .accounts)
    }

    // MARK: - What the panel is allowed to show

    /// The panel is drawn as soon as it opens, before the refresh behind it finishes. A
    /// stale route used to paint "No accounts on this key" — with a Create button — under a
    /// header reading "Locked". The account list of a locked key is unread, not empty.
    func testALockedKeyAlwaysShowsThePinScreen() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        store.lockSelectedKey()
        store.show(.accounts)

        XCTAssertEqual(store.effectiveRoute, .unlock)
    }

    /// Key info needs neither PIN nor touch, so it is the one screen a locked key may show.
    func testKeyInfoSurvivesALockedKey() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
        store.show(.keyInfo)
        store.lockSelectedKey()

        XCTAssertEqual(store.effectiveRoute, .keyInfo)
    }

    /// ⌘N while the key is locked: unlock first, then land on the screen that was asked for.
    func testAScreenRequestedWhileLockedSurvivesUnlocking() async {
        let (store, _, _) = await HUDTestFactory.unlockedStore()
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
        let (store, _, device) = await HUDTestFactory.unlockedStore()
        XCTAssertFalse(store.isPinnedOpen)

        store.show(.backupKey(AccountRef(accountId: "vault", devicePath: device.path)))
        XCTAssertTrue(store.isPinnedOpen)

        store.backToAccounts()
        XCTAssertFalse(store.isPinnedOpen)
    }

    /// A key that cannot be read looks exactly like a key with nothing on it. Saying which
    /// one it is matters most for the person whose accounts have just "disappeared".
    func testAnUnreadableKeyExplainsItselfInsteadOfLookingEmpty() async {
        let (store, backend, _) = await HUDTestFactory.unlockedStore()
        backend.enumerateError = TestError.generic("Key is busy")

        await store.refresh()

        XCTAssertTrue(store.accounts.accounts.isEmpty)
        XCTAssertNotNil(store.errorText, "an empty list with no explanation is the worst of both")
    }

    /// The bug that made the HUD hang on "no security key connected" after one successful
    /// generation: enumeration failed for a moment, and the failure was read as "the desk is
    /// empty" — releasing the PIN token and every account of a key that never moved.
    func testEnumerationFailureDoesNotLookLikeAnUnpluggedKey() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        XCTAssertFalse(store.devices.devices.isEmpty)

        backend.listDevicesError = TestError.generic("device busy")
        await store.refresh()

        XCTAssertEqual(store.devices.devices.map(\.path), [device.path], "the key must survive a failed read")
        XCTAssertTrue(store.isSelectedKeyUnlocked, "and so must its unlocked state")
        XCTAssertFalse(store.accounts.accounts.isEmpty)
        XCTAssertNotNil(store.errorText, "but the user has to be told the read failed")
    }

    /// A key re-enumerates on the HID bus right after it is touched, so a single empty read
    /// in that window is noise rather than an unplug.
    func testOneEmptyReadAfterATouchIsNotAnUnplug() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        backend.listDevicesResults = [[], [device]]

        await store.refresh()

        XCTAssertEqual(store.devices.devices.map(\.path), [device.path])
        XCTAssertTrue(store.isSelectedKeyUnlocked)
    }

    func testUnpluggingAKeyClearsItsState() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
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
final class HUDEditorLifetimeTests: XCTestCase {

    func testLockingTheKeyClosesTheEditor() async {
        let (store, _, device) = await HUDTestFactory.unlockedStore()
        var closed = false
        store.onRequestOpenEditor = { _ in }
        store.onRequestCloseEditor = { closed = true }

        await store.openEncryptEditor(for: AccountRef(accountId: "vault", devicePath: device.path))
        XCTAssertEqual(store.editorDevicePath, device.path)

        store.lockSelectedKey()
        XCTAssertTrue(closed, "locking must not leave a live key in an open window")
        XCTAssertNil(store.editorDevicePath)
    }

    func testUnpluggingTheKeyClosesTheEditor() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        var closed = false
        store.onRequestOpenEditor = { _ in }
        store.onRequestCloseEditor = { closed = true }
        await store.openEncryptEditor(for: AccountRef(accountId: "vault", devicePath: device.path))

        backend.devices = []
        await store.refresh()
        XCTAssertTrue(closed)
    }

    func testAnEmptyLabelIsRefusedBeforeTheKeyIsTouched() async {
        let (store, backend, device) = await HUDTestFactory.unlockedStore()
        store.setLabel("   ")
        await store.openEncryptEditor(for: AccountRef(accountId: "vault", devicePath: device.path))

        XCTAssertNotNil(store.errorText)
        XCTAssertNil(store.editorDevicePath)
        XCTAssertTrue(backend.generateCalls.isEmpty)
    }
}
