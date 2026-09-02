import Combine
import FidoPassCore
import Foundation

/// The single object the HUD views talk to.
///
/// It owns navigation, and it is the only place allowed to start an operation on the key —
/// which is what guarantees the touch prompt is always raised. A view reaching past it into
/// a store is a bug: that is exactly how the app once ended up looking frozen while the key
/// silently waited for a finger.
@MainActor
final class PanelStore: ObservableObject {

    @Published private(set) var route: PanelRoute = .accounts
    @Published var error: PresentedError?
    @Published private(set) var statusText: String?
    @Published var selection: AccountRef?
    @Published var pinDraft: String = ""
    /// Value being shown on the backup-key screen. Never persisted, dropped on leaving.
    @Published private(set) var backup: PortableBackup?
    @Published var enrollDraft = EnrollDraft() {
        didSet {
            // A backup from before identities has none. The moment one is recognised the
            // identity field gets a random value, so Import is one click away; it stays
            // editable for the case where the same account already shows one on another key.
            if enrollDraft.importIsLegacy, enrollDraft.legacyIdentityHex.isEmpty {
                enrollDraft.legacyIdentityHex = AccountIdentity.random().groupedHex
            }
        }
    }
    @Published private(set) var enrollStep: String?
    /// The identity about to be written by the migration screen. Reset each time it opens.
    @Published var migrationDraft = MigrationDraft()
    /// Set while a system panel of our own is up — a save dialog takes key status away, and
    /// the HUD must not vanish behind it.
    @Published private(set) var isShowingSystemPanel = false

    let devices: DeviceStore
    let accounts: AccountStore
    let generation: GenerationStore
    /// What the manager window has read. Empty until that window asks for something.
    let inventory: InventoryStore
    let labels: LabelStore
    let preferences: Preferences
    /// The one door to the key. Shared with the manager; the panel draws only its own waits.
    let touchGate: TouchGate
    let editor: EditorCoordinator
    /// The windows. A window, not a route, for anything that has to survive the panel closing
    /// behind it — the manager, the editor — and for the panel itself.
    let router: WindowRouter
    /// The bootstrap form. Separate from `pinDraft`, which is the unlock field: a half-typed
    /// new PIN must never be submitted as an unlock attempt.
    let pinForm: PinFormModel
    /// The label row: the label the next password derives from, and the field it is typed in.
    let labelEditor: LabelEditor

    private var pendingIntent: PanelIntent?
    private var subscriptions: Set<AnyCancellable> = []
    private var statusTask: Task<Void, Never>?

    init(devices: DeviceStore,
         accounts: AccountStore,
         generation: GenerationStore,
         inventory: InventoryStore,
         labels: LabelStore,
         preferences: Preferences,
         touchGate: TouchGate,
         editor: EditorCoordinator,
         router: WindowRouter) {
        self.devices = devices
        self.accounts = accounts
        self.generation = generation
        self.inventory = inventory
        self.labels = labels
        self.preferences = preferences
        self.touchGate = touchGate
        self.editor = editor
        self.router = router
        self.pinForm = PinFormModel(mode: .bootstrap,
                                    devices: devices,
                                    touchGate: touchGate,
                                    surface: .panel,
                                    device: { [weak devices] in devices?.selectedState?.device })
        self.labelEditor = LabelEditor(history: labels)
        // Switching label drops a password derived from the previous one, whichever way the
        // switch happened — a chip, the keyboard, typing. Otherwise copying would hand over a
        // secret derived from something else.
        labelEditor.$current
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] label in
                guard let self, let selection = self.selection else { return }
                self.generation.invalidateResult(unless: selection, label: label)
            }
            .store(in: &subscriptions)
    }

    // MARK: - Derived state

    var selectedDevice: FidoDevice? { devices.selectedState?.device }
    /// The touch prompt the panel draws, if the current wait is the panel's.
    var touch: TouchPrompt? { touchGate.panelPrompt }
    /// A key operation is in flight — the panel's or another window's.
    var isWorking: Bool { touchGate.isWorking }
    var busyTitle: String? { touchGate.panelBusyTitle }
    var isSelectedKeyUnlocked: Bool { devices.selectedState?.unlocked == true }

    var visibleAccounts: [AccountHandle] {
        guard let path = devices.selectedPath else { return [] }
        return accounts.accounts(onDevice: path)
    }

    /// What the PIN screen says the unlock is *for*.
    ///
    /// Without it, unlocking looks like a detour; with it, the user can see that the thing
    /// they asked for is still queued and will happen the moment the key opens.
    var pendingSummary: String? {
        switch pendingIntent {
        case .copyPassword(let ref, let label):
            return "Unlock to copy the password for “\(ref.accountId)” · label “\(label)”."
        case .revealPassword(let ref, let label):
            return "Unlock to show the password for “\(ref.accountId)” · label “\(label)”."
        case .enroll:
            return "Unlock to create a new account on this key."
        case .none:
            return nil
        }
    }

    var snapshot: PanelSnapshot {
        PanelSnapshot(hasDevices: !devices.devices.isEmpty,
                    selectedDevicePath: devices.selectedPath,
                    isUnlocked: isSelectedKeyUnlocked,
                    keyHasPIN: devices.selectedState?.hasPIN,
                    accountRefs: visibleAccounts.map(AccountRef.init),
                    legacyRefs: Set(visibleAccounts.filter { $0.account.needsMigration }.map(AccountRef.init)),
                    selection: selection)
    }

    /// What `⏎` is expected to do in the current state.
    ///
    /// Read by the tests that pin the click budget, not by the panel: each screen owns its
    /// own default button, because a second, global Return handler used to fire alongside
    /// the focused field's submit and spend two PIN attempts on one keypress. This is the
    /// statement of what those buttons must add up to, checked against real store state.
    var primaryAction: PanelPrimaryAction { PanelReducer.primaryAction(snapshot) }

    /// What may actually be shown, given the state of the key.
    ///
    /// `route` is an intention; this is the truth. Deriving it here rather than trusting
    /// every code path to keep `route` in step is what stops the panel from claiming
    /// "no accounts on this key" under a header that says the key is locked — its account
    /// list is not empty, it is unread, and the two must never look the same.
    var effectiveRoute: PanelRoute {
        // Ahead of the "is a key present" check, because no key is a *step* of this wizard:
        // it asks the user to unplug, and the key being gone is what it waits for. Falling
        // through to "No security key connected" made the wizard vanish at exactly the moment
        // it was doing its job.
        guard !devices.devices.isEmpty else { return .accounts }
        // A key that says it must have its PIN changed will refuse every other operation, and
        // silent refusals are impossible to explain. Changing it proves knowledge of the old
        // PIN, so this works on a locked key too.
        if devices.selectedState?.forcePINChange == true { return .pinChangeRequired }
        guard isSelectedKeyUnlocked else {
            // A key with no PIN cannot be unlocked at all; offering the field would be a dead
            // end, which is exactly what it used to be.
            if devices.selectedState?.hasPIN == false { return .setPIN }
            if case .pinChangeRequired = route { return .pinChangeRequired }
            return .unlock
        }
        return route
    }

    /// State the menu-bar icon renders.
    var iconState: StatusItemIcon.State {
        if touchGate.prompt != nil { return .waitingForTouch }
        if devices.devices.isEmpty { return .noKey }
        if generation.receipt?.clearsAt != nil { return .clipboardHot }
        return isSelectedKeyUnlocked ? .unlocked : .locked
    }

    // MARK: - Lifecycle

    /// Called every time the panel is about to appear.
    func prepareForDisplay(intent: PanelIntent? = nil) async {
        error = nil
        await devices.refresh()
        if let failure = devices.refreshError { error = failure }
        await readStatusOfLockedKey()
        await reloadAccountsIfNeeded()
        restoreSelectionIfNeeded()

        if let intent {
            pendingIntent = intent
        }
        route = isSelectedKeyUnlocked ? .accounts : (devices.devices.isEmpty ? .accounts : .unlock)
        if isSelectedKeyUnlocked { await runPendingIntentIfPossible() }
    }

    func panelDidClose() {
        pinDraft = ""
        pinForm.clear()
        error = nil
        backup = nil
        enrollStep = nil
        // The reset wizard is not touched here any more: it runs in the manager window, and
        // closing the panel — which happens the moment that window takes focus — must not
        // disarm a reset the user is halfway through.
        if case .accounts = route {} else { route = .accounts }
    }

    /// Asks the selected key about itself — but only when the panel is being opened.
    ///
    /// Opening a key seizes it from every other process on macOS, so the app may not do it
    /// merely because a key was plugged in: that is how a running FidoPass used to make
    /// `ykman fido reset` impossible. Opening the panel *is* a request, and it is the moment
    /// the answers are needed — whether the key has a PIN decides which screen to show, and
    /// the attempts left have to be on screen before one is spent.
    ///
    /// Skipped for an unlocked key: it demonstrably has a PIN, and its state is already known.
    private func readStatusOfLockedKey() async {
        guard let device = selectedDevice, devices.selectedState?.unlocked != true else { return }
        await devices.refreshStatus(for: device)
    }

    private func reloadAccountsIfNeeded() async {
        let unlocked = devices.unlockedPaths
        guard !unlocked.isEmpty else {
            accounts.dropAll()
            return
        }
        await accounts.reload(unlockedPaths: unlocked)
        // An unreadable key would otherwise look like a key with no accounts on it.
        if let path = devices.selectedPath, let failure = accounts.readErrors[path] {
            error = failure
        }
    }

    private func restoreSelectionIfNeeded() {
        let visible = visibleAccounts
        let resolved = selection.flatMap { visible.contains(where: $0.matches) ? $0 : nil }
            ?? PanelReducer.resolveSelection(accounts: visible,
                                           devices: devices.devices,
                                           memory: preferences.lastUsed)
        // Nothing is re-resolved when the account and its history are already the ones on
        // screen: a refresh must not throw away a label the user has just typed. Note that a
        // reconnect changes the path but not the scope, so the label survives it.
        guard selection != resolved || labels.scope != labelTarget(for: resolved)?.scope else { return }
        selection = resolved
        focusLabels(on: resolved)
    }

    /// Where this account's label history is kept, and how to describe it.
    ///
    /// Built here rather than inside `LabelStore`, which never sees a device: identity is the
    /// credential id, and the key's name is read from the device it is plugged into right
    /// now — the path that leads to it is a session handle and is never stored.
    func labelTarget(for ref: AccountRef?) -> LabelTarget? {
        guard let ref,
              let account = accounts.account(ref),
              let state = devices.state(for: ref.devicePath) else { return nil }
        return LabelTarget(scope: LabelScope(credentialId: account.credentialIdB64),
                           accountId: account.id,
                           deviceSignature: state.device.modelSignature,
                           deviceName: state.device.displayName)
    }

    private func focusLabels(on ref: AccountRef?) {
        labelEditor.focus(labelTarget(for: ref))
    }

    // MARK: - Navigation

    func show(_ route: PanelRoute) {
        self.route = route
        if case .backupKey = route {} else { backup = nil }
    }

    /// Whether clicking away must leave the panel open.
    ///
    /// Derived from what is on screen, not remembered from the last `show(_:)`. It used to be
    /// stored, and then a screen the user never navigated to — unplugging the key turns the
    /// reset wizard into "no security key" — left the panel pinned by a route nobody could
    /// see. The result was a HUD that would not close and gave no reason why.
    var isPinnedOpen: Bool {
        if isShowingSystemPanel { return true }
        switch effectiveRoute {
        case .accounts, .unlock:
            return false
        case .setPIN:
            // It can appear on its own — a key with no PIN — so it holds the panel only once
            // there is typing in it to lose.
            return !pinForm.isEmpty
        case .pinChangeRequired:
            return false
        case .enroll, .backupKey, .confirmDelete, .migrate:
            return true
        }
    }

    func backToAccounts() {
        show(.accounts)
        error = nil
    }

    func select(_ ref: AccountRef) {
        selection = ref
        // The label moves with the account, so the result is judged against the new label —
        // otherwise a password derived from the previous one would stay on screen under an
        // account it does not belong to.
        focusLabels(on: ref)
        generation.invalidateResult(unless: ref, label: labelEditor.current)
    }

    /// Moves the selection by one row. Clamped rather than wrapping: with two or three
    /// accounts, silently jumping from the last to the first is a way to derive the wrong
    /// password without noticing.
    func moveSelection(by offset: Int) {
        let refs = visibleAccounts.map(AccountRef.init)
        guard !refs.isEmpty else { return }
        let current = selection.flatMap { refs.firstIndex(of: $0) } ?? 0
        let next = min(max(current + offset, 0), refs.count - 1)
        guard next != current || selection == nil else { return }
        select(refs[next])
    }

    func selectAccount(at index: Int) {
        let refs = visibleAccounts.map(AccountRef.init)
        guard refs.indices.contains(index) else { return }
        select(refs[index])
    }

    func selectKey(path: String) {
        devices.selectedPath = path
        selection = nil
        restoreSelectionIfNeeded()
        route = devices.selectedState?.unlocked == true ? .accounts : .unlock
    }

    func setLabel(_ label: String) {
        labelEditor.set(label)
    }

    /// Escape: leave the screen, not the app.
    ///
    /// - Returns: true when the store handled it; false means the panel should close.
    func handleEscape() -> Bool {
        if labelEditor.escape() { return true }
        switch route {
        case .accounts, .unlock:
            return false
        case .setPIN:
            // There is nowhere to go back to: every other screen needs a PIN this key has not
            // got. Escape closes the panel, as it does on the account list.
            return false
        case .pinChangeRequired:
            // Nowhere to go back to: the key refuses everything until the PIN is changed.
            return true
        case .enroll, .backupKey, .confirmDelete, .migrate:
            backToAccounts()
            return true
        }
    }

    /// Shortcuts worth printing at the bottom of the panel.
    ///
    /// Nothing about "⏎ copies the password" is guessable, and a shortcut nobody knows about
    /// is the same as one that does not exist.
    var keyboardHints: [String] {
        switch effectiveRoute {
        case .unlock:
            return ["⏎ unlock"]
        case .setPIN:
            return ["⏎ set PIN"]
        case .pinChangeRequired:
            return []
        case .enroll:
            return ["⏎ create", "esc cancel"]
        case .backupKey:
            return ["esc back"]
        case .confirmDelete:
            return ["esc cancel"]
        case .migrate:
            return ["⏎ migrate", "esc cancel"]
        case .accounts:
            guard !devices.devices.isEmpty else { return [] }
            guard !visibleAccounts.isEmpty else { return ["⌘N new account"] }
            if labelEditor.isEditing { return ["⏎ copy", "esc done"] }
            var hints = ["⏎ copy", "⌘⏎ show"]
            if visibleAccounts.count > 1 { hints.append("↑↓ account") }
            if !labels.chips.isEmpty { hints.append("←→ label") }
            hints.append("⌘N new")
            return hints
        }
    }

    // MARK: - Unlock

    private var statusRequestedForDraft = false

    /// Asks the key how many attempts are left — on the first character typed, not when the
    /// PIN screen appears, and only for a key nobody has asked yet.
    ///
    /// The PIN screen appears the moment a key is plugged in, and opening a key seizes it
    /// (`libfido2/src/hid_osx.c`, `kIOHIDOptionsTypeSeizeDevice`). That is how a running
    /// FidoPass used to break `ykman fido reset`: the key was taken over within a second of
    /// being connected, before its owner had asked for anything. Typing a PIN is asking; the
    /// key being present is not. A key the panel already asked when it opened is not asked
    /// again: its state is known, and a second open buys nothing.
    func pinDraftDidChange() async {
        guard !pinDraft.isEmpty else {
            statusRequestedForDraft = false
            return
        }
        guard !statusRequestedForDraft,
              let device = selectedDevice,
              devices.state(for: device.path)?.hasPIN == nil else { return }
        statusRequestedForDraft = true
        await devices.refreshStatus(for: device)
    }

    func submitPin() async {
        // A PIN attempt is a scarce resource: eight consecutive failures kill the key for
        // good. Return can reach here twice — the field's submit action and the default
        // button — and two attempts must never be spent on one keypress.
        guard !isWorking else { return }
        guard let device = selectedDevice, !pinDraft.isEmpty else { return }
        let pin = pinDraft
        do {
            try await touchGate.withBusy("Checking the PIN…") {
                try await devices.unlock(device, pin: pin)
                pinDraft = ""
                error = nil
                await reloadAccountsIfNeeded()
                restoreSelectionIfNeeded()
                // Only the PIN screen is replaced: a screen requested while the key was locked
                // (⌘N, say) is still what the user is waiting for.
                if route == .unlock { route = .accounts }
            }
            // Outside the busy scope: the queued action is an operation in its own right, and
            // it has to pass the same guard as if the user had asked for it now.
            await runPendingIntentIfPossible()
        } catch {
            pinDraft = ""
            present(error)
        }
    }

    // MARK: - PIN bootstrap

    /// Bootstrap: this key has never had a PIN. Changing one lives in the manager.
    func setInitialPIN() async {
        do {
            let accepted = try await pinForm.submit {
                error = nil
                await reloadAccountsIfNeeded()
                restoreSelectionIfNeeded()
                route = .accounts
            }
            guard accepted else { return }
            setStatus("PIN set — this key is ready to use")
            await runPendingIntentIfPossible()
        } catch {
            present(error, whenRefused: "This key already has a PIN. Use “Change PIN…” instead.")
        }
    }

    func lockSelectedKey() {
        guard let path = devices.selectedPath else { return }
        devices.lock(path: path)
    }

    private func runPendingIntentIfPossible() async {
        guard let intent = pendingIntent, isSelectedKeyUnlocked else { return }
        pendingIntent = nil
        switch intent {
        case .copyPassword(let ref, let label):
            await copyPassword(for: resolved(ref) ?? selection, label: label)
        case .revealPassword(let ref, let label):
            await revealPassword(for: resolved(ref) ?? selection, label: label)
        case .enroll:
            show(.enroll)
        }
    }

    /// Re-resolves a reference across a reconnect: the account is the same, the path is not.
    private func resolved(_ ref: AccountRef) -> AccountRef? {
        if accounts.account(ref) != nil { return ref }
        guard let path = devices.selectedPath else { return nil }
        let candidate = AccountRef(accountId: ref.accountId, devicePath: path)
        return accounts.account(candidate) != nil ? candidate : nil
    }

    /// Queues what the user asked for so it survives the PIN prompt.
    func requestIntent(_ intent: PanelIntent) {
        pendingIntent = intent
    }

    // MARK: - Passwords

    func copyPassword(for ref: AccountRef?, label: String? = nil) async {
        await generate(for: ref, label: label, reveal: false)
    }

    func revealPassword(for ref: AccountRef?, label: String? = nil) async {
        await generate(for: ref, label: label, reveal: true)
    }

    private func generate(for ref: AccountRef?, label: String?, reveal: Bool) async {
        guard !isWorking, generation.busyRef == nil else { return }
        guard let ref, let account = accounts.account(ref) else { return }
        guard isSelectedKeyUnlocked else {
            requestIntent(reveal ? .revealPassword(ref, label: label ?? labelEditor.current)
                                 : .copyPassword(ref, label: label ?? labelEditor.current))
            route = .unlock
            return
        }
        // An account from before identities would derive exactly what it always did — the
        // identity is not an input — but it is refused until it has one, so that every
        // account on screen can be told from its namesake on another key. The screen it
        // lands on explains that and does the one thing there is to do.
        if account.account.needsMigration {
            beginMigration(ref)
            return
        }
        let usedLabel = (label ?? labelEditor.current).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !usedLabel.isEmpty else {
            error = .plain("Enter a label first — it is part of the derivation.")
            return
        }

        // Generating for an account that was not the selected one makes it the selected one,
        // its history included — otherwise the chips would go on describing the previous
        // account while the result on screen belongs to this one. The label itself is left
        // alone: it is the one this generation is running with.
        selection = ref
        labels.focus(labelTarget(for: ref))
        do {
            let password = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                                 message: "Keep it in contact until the password appears.",
                                                                 deviceName: selectedDevice?.displayName ?? "Security key")) {
                try await self.generation.generate(account, label: usedLabel)
            }
            if let target = labelTarget(for: ref) { labels.use(usedLabel, in: target) }
            labelEditor.adopt(usedLabel)
            if let device = selectedDevice {
                preferences.remember(accountId: ref.accountId, label: usedLabel, device: device)
            }
            if reveal {
                generation.reveal(true)
                setStatus("Shown on screen only — not copied")
            } else {
                generation.copy(password, as: .password, for: ref)
                setStatus("Password copied — the clipboard clears itself")
            }
        } catch {
            present(error)
        }
    }

    func toggleReveal() {
        guard let result = generation.result else { return }
        generation.reveal(!result.revealed)
    }

    func copyCurrentResult() {
        guard let result = generation.result else { return }
        generation.copy(result.password, as: .password, for: result.ref)
        setStatus("Password copied — the clipboard clears itself")
    }

    // MARK: - Enrolment

    func createAccount() async {
        guard !isWorking else { return }
        guard let request = enrollDraft.request,
              let path = devices.selectedPath,
              let device = selectedDevice else { return }
        let draft = enrollDraft

        do {
            let created = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                                message: request.kind == .portable
                                                                    ? "Step 1 of 2 — creating the credential."
                                                                    : "Confirming with the key.",
                                                                deviceName: device.displayName)) {
                try await self.accounts.enroll(accountId: draft.trimmedId,
                                               request: request,
                                               devicePath: path) { step in
                    Task { @MainActor in self.enrollStep = Self.stepMessage(step) }
                }
            }
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
            enrollStep = nil
            present(error)
        }
    }

    /// A fresh identity for a backup that predates them. The one the form filled in is
    /// random too; this is for someone who typed over it and wants a random one back.
    func randomiseImportIdentity() {
        enrollDraft.legacyIdentityHex = AccountIdentity.random().groupedHex
    }

    static func stepMessage(_ step: PortableEnrollmentStep) -> String {
        switch step {
        case .creatingCredential: return "Step 1 of 2 — touch your key to create the credential"
        case .derivingBackupKey:  return "Step 2 of 2 — touch your key again to derive its backup key"
        case .savingPayload:      return "Saving to the key…"
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

    /// Opens the migration screen for an account from before identities, with a fresh random
    /// identity to accept or replace.
    func beginMigration(_ ref: AccountRef) {
        guard let account = accounts.account(ref), account.account.needsMigration else { return }
        migrationDraft = MigrationDraft()
        selection = ref
        show(.migrate(ref))
    }

    /// Writes the chosen identity to the key. PIN only, no touch — the material, and so every
    /// password, stays exactly as it is.
    func migrate() async {
        guard !isWorking else { return }
        guard case .migrate(let ref) = route,
              let account = accounts.account(ref),
              account.account.needsMigration,
              let identity = migrationDraft.identity else { return }
        do {
            try await touchGate.withBusy("Migrating “\(ref.accountId)”…") {
                _ = try await accounts.assignIdentity(account, identity: identity)
            }
            select(ref)
            show(.accounts)
            setStatus("Account migrated — passwords are unchanged")
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
        generation.copy(backup.base64, as: .backupKey, for: ref)
        setStatus("Backup key copied — store it offline, not in a password manager")
    }

    func saveRecoverySheet(for ref: AccountRef) {
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

    // MARK: - Text encryption

    func openEncryptEditor(for ref: AccountRef) async {
        guard !isWorking else { return }
        guard let account = accounts.account(ref) else { return }
        // Same rule as generating: nothing is derived from an account until it has an
        // identity. The backup key is the one exception — see `showBackupKey`.
        if account.account.needsMigration {
            beginMigration(ref)
            return
        }
        let label = labelEditor.current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            error = .plain("Enter a label first — the key is derived from it.")
            return
        }
        do {
            let key = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                            message: "Deriving the key for this editing session.",
                                                            deviceName: selectedDevice?.displayName ?? "Security key")) {
                try await self.accounts.deriveEncryptionKey(for: account, label: label)
            }
            if let target = labelTarget(for: ref) { labels.use(label, in: target) }
            let session = CryptoEditorSession(account: account.account, label: label, key: key, cipher: accounts.cipher)
            editor.open(session, boundTo: ref.devicePath)
            router.closePanel()
        } catch {
            present(error)
        }
    }

    // MARK: - Touch prompt

    /// The panel's door to the key — `TouchGate`, with the prompt drawn here.
    func withTouchPrompt<T>(_ prompt: TouchPrompt, _ body: () async throws -> T) async rethrows -> T {
        try await touchGate.withTouchPrompt(prompt, surface: .panel, body)
    }

    func abandonTouch() {
        touchGate.abandonTouch()
    }

    // MARK: - Housekeeping

    /// Opens the manager window. Reads nothing by itself — the window asks first.
    func openManager() {
        router.openManager()
        router.closePanel()
    }

    func openPreferences() {
        router.openPreferences()
    }

    func quit() {
        router.quit()
    }

    /// A key stopped being usable. The container has already dropped what the other stores
    /// held for it; this is only what the panel itself was showing.
    func keyDidClose(_ path: String) {
        if selection?.devicePath == path {
            selection = nil
            focusLabels(on: nil)
        }
        // The backup key on screen was derived from the key that just went away; it must not
        // outlive it, and there is nothing to come back to.
        if case .backupKey = route {
            backup = nil
            route = .accounts
        }
        // Likewise a migration: the account it was for is gone with the key.
        if case .migrate = route {
            route = .accounts
        }
    }

    /// The machine locked. Every key is locked by now and every store emptied; the panel
    /// goes back to the PIN field and out of sight.
    func sessionDidLock() {
        backup = nil
        selection = nil
        focusLabels(on: nil)
        route = .unlock
        router.closePanel()
    }

    /// The key was erased. It now has no PIN, which is where `effectiveRoute` sends it —
    /// straight into bootstrap. Leaving the user on an empty account list would be the dead
    /// end the whole reset flow exists to remove.
    func resetDidComplete() {
        route = .accounts
        setStatus("Key erased — set a new PIN to use it")
    }

    func refresh() async {
        await devices.refresh()
        if let failure = devices.refreshError { error = failure }
        await reloadAccountsIfNeeded()
        restoreSelectionIfNeeded()
    }

    private func present(_ failure: Error) {
        error = PresentedError(failure)
    }

    /// Presents an error, supplying the meaning of a bare refusal — see
    /// `PresentedError.init(_:meaningOfRefusal:)`.
    private func present(_ failure: Error, whenRefused meaning: String) {
        error = PresentedError(failure, meaningOfRefusal: meaning)
    }

    private func setStatus(_ text: String) {
        statusText = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.statusText = nil
        }
    }

}
