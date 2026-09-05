import Combine
import FidoPassCore
import Foundation

/// HUD navigation and actions. Key operations use the shared TouchGate.
@MainActor
final class PanelStore: ObservableObject {

    @Published private(set) var route: PanelRoute = .accounts
    @Published var error: PresentedError?
    @Published private(set) var statusText: String?
    @Published var selection: AccountRef?
    @Published var pinDraft: String = ""
    @Published var backup: PortableBackup?
    @Published var enrollStep: String?
    @Published var migrationDraft = MigrationDraft()
    @Published var enrollDraft = EnrollDraft() {
        didSet {
            if enrollDraft.hasUnadoptedImportIdentity { enrollDraft.adoptImportIdentityIfNeeded() }
        }
    }
    private(set) var accountFlowLease = OperationLease()
    /// Set while a system panel of our own is up — a save dialog takes key status away, and
    /// the HUD must not vanish behind it.
    @Published var isShowingSystemPanel = false

    let devices: DeviceStore
    let accounts: AccountStore
    let generation: GenerationStore
    /// What the manager window has read. Empty until that window asks for something.
    let inventory: InventoryStore
    let labels: LabelStore
    let preferences: Preferences
    /// The one door to the key. Shared with the manager; the panel draws only its own waits.
    let touchGate: TouchGate
    let decryptor: DecryptorCoordinator
    /// The windows. A window, not a route, for anything that has to survive the panel closing
    /// behind it — the manager, the message windows — and for the panel itself.
    let router: WindowRouter
    /// The bootstrap form. Separate from `pinDraft`, which is the unlock field: a half-typed
    /// new PIN must never be submitted as an unlock attempt.
    let pinForm: PinFormModel
    /// The label row: the label the next password derives from, and the field it is typed in.
    let labelEditor: LabelEditor

    private var lifetime = OperationLease()
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
         decryptor: DecryptorCoordinator,
         router: WindowRouter) {
        self.devices = devices
        self.accounts = accounts
        self.generation = generation
        self.inventory = inventory
        self.labels = labels
        self.preferences = preferences
        self.touchGate = touchGate
        self.decryptor = decryptor
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
            .removeDuplicates(by: { $0.utf8.elementsEqual($1.utf8) })
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
    /// Whether the selected key can hold a v2 account at all. Every new account keeps its
    /// record in the key's large-blob store; a key without one — older firmware — can only
    /// go on serving what is already on it. `nil` from the key reads as "yes": only a
    /// definite refusal closes anything.
    var selectedKeyHoldsRecords: Bool { devices.selectedState?.supportsLargeBlobs != false }

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
        case .decrypt:
            return "Unlock to decrypt a message."
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
                    legacyRefs: Set(visibleAccounts.filter { isMigratable($0) }.map(AccountRef.init)),
                    incompleteRefs: Set(visibleAccounts.filter { !$0.account.canDerive }.map(AccountRef.init)),
                    selection: selection)
    }

    /// A v1 portable account on a key that can take the v2 copy. On a key without a
    /// large-blob store there is nothing to migrate into, and the account goes on deriving
    /// what it always did rather than being refused for a migration that cannot happen.
    func isMigratable(_ handle: AccountHandle) -> Bool {
        handle.account.needsMigration && devices.state(for: handle.devicePath)?.supportsLargeBlobs != false
    }

    /// Default-action contract checked by tests. Screens own their default buttons;
    /// a second Return dispatcher would submit twice.
    var primaryAction: PanelPrimaryAction { PanelReducer.primaryAction(snapshot) }

    /// Resolves the requested route against current key availability and PIN state.
    var effectiveRoute: PanelRoute {
        guard !devices.devices.isEmpty else { return .accounts }
        // A required PIN change blocks other operations, including unlock.
        if devices.selectedState?.forcePINChange == true { return .pinChangeRequired }
        guard isSelectedKeyUnlocked else {
            // A new key needs to set its PIN before it can unlock.
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

    private func clearAccountFlow() {
        accountFlowLease.invalidate()
        accountFlowLease = OperationLease()
        backup = nil
        enrollStep = nil
        enrollDraft = EnrollDraft()
        migrationDraft = MigrationDraft()
    }

    // MARK: - Lifecycle

    /// Called every time the panel is about to appear.
    func prepareForDisplay(intent: PanelIntent? = nil, readKey: Bool = true) async {
        let token = lifetime
        error = nil
        await devices.refresh()
        if let failure = devices.refreshError { error = failure }
        guard token.isValid else { return }
        if readKey {
            await readStatusOfLockedKey()
            guard token.isValid else { return }
            await reloadAccountsIfNeeded()
        }
        guard token.isValid else { return }
        restoreSelectionIfNeeded()

        if let intent {
            pendingIntent = intent
        }
        route = isSelectedKeyUnlocked ? .accounts : (devices.devices.isEmpty ? .accounts : .unlock)
        if isSelectedKeyUnlocked { await runPendingIntentIfPossible() }
    }

    func panelDidClose() {
        clearAccountFlow()
        lifetime.invalidate()
        lifetime = OperationLease()
        if touchGate.surface == .panel { touchGate.abandonTouch() }
        generation.clearResult()
        enrollDraft.importText = ""
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

    /// Probes a locked key when the HUD is explicitly opened, never on passive hot-plug.
    /// Unlocked keys already have known state.
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

    func restoreSelectionIfNeeded() {
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
        if case .enroll = self.route { enrollDraft.importText = "" }
        self.route = route
        if case .backupKey = route {} else { backup = nil }
    }

    /// Whether the currently visible screen must stay open when focus moves away.
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
        if devices.selectedPath != path { panelDidClose() }
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

    /// Probes unknown PIN state on the first typed character. Typing is a user request;
    /// merely showing the unlock screen after hot-plug must not seize the key.
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
            await copyPassword(for: resolved(ref), label: label)
        case .revealPassword(let ref, let label):
            await revealPassword(for: resolved(ref), label: label)
        case .enroll:
            show(.enroll)
        case .decrypt(let message):
            openDecryptor(prefilled: message)
        }
    }

    /// Re-resolves a reference across a reconnect: the account is the same, the path is not.
    private func resolved(_ ref: AccountRef) -> AccountRef? {
        if accounts.account(ref) != nil { return ref }
        let matches = accounts.accounts.filter { $0.credentialIdB64 == ref.credentialId }
        return matches.count == 1 ? matches.first.map(AccountRef.init) : nil
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
        // A credential without a usable record is not an account. Nothing is derived from
        // it, and the one thing to do with it is delete it.
        if let problem = account.account.integrity.problem {
            error = .plain(problem)
            return
        }
        // A v1 portable account would derive exactly what it always did, but it is refused
        // until it has been migrated — the screen it lands on explains that and does the
        // one thing there is to do. On a key that cannot take the copy it derives as before.
        if isMigratable(account) {
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
                preferences.remember(accountId: ref.accountId, label: usedLabel, device: device, credentialId: account.credentialIdB64)
            }
            if reveal {
                generation.reveal(true)
                setStatus("Shown on screen only — not copied")
            } else {
                guard generation.copy(password, as: .password, for: ref) else {
                    error = .plain("Could not write to the clipboard.")
                    return
                }
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
        guard generation.copy(result.password, as: .password, for: result.ref) else {
            error = .plain("Could not write to the clipboard.")
            return
        }
        setStatus("Password copied — the clipboard clears itself")
    }

    // MARK: - Messages

    /// Issues an encryption key for an account: one touch, then the sending window opens
    /// with the link in it. Every press mints a new key — a new nonce — and every key ever
    /// issued keeps working, because a message carries the nonce it was sealed under.
    func issueEncryptionKey(for ref: AccountRef) async {
        guard !isWorking else { return }
        guard let account = accounts.account(ref) else { return }
        if let problem = account.account.integrity.problem {
            error = .plain(problem)
            return
        }
        // A v1 portable account has no identity, so no locator: no message could find it.
        // Migration is the way to one — or, on a key that cannot take the copy, nothing is.
        if account.account.needsMigration {
            if isMigratable(account) {
                beginMigration(ref)
            } else {
                error = .plain("“\(ref.accountId)” cannot issue encryption keys: it was created by an earlier version, and this key cannot hold the current format.")
            }
            return
        }
        do {
            var key = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                            message: "Issuing an encryption key for “\(ref.accountId)”.",
                                                            deviceName: selectedDevice?.displayName ?? "Security key")) {
                try await self.accounts.deriveMessageKey(for: account, nonce: EncryptionKeyURL.randomNonce())
            }
            // Only the link leaves here. The private half is for opening messages, which is
            // the other window's business and another touch.
            key.wipe()
            router.openEncryptor(with: key.url, issuedFor: account.account)
            router.closePanel()
            setStatus("Encryption key issued — share the link, compare the emoji")
        } catch {
            present(error)
        }
    }

    /// The sending window, empty or with a key that was clicked as a link. Needs no security
    /// key at all.
    func openEncryptor(with key: EncryptionKeyURL? = nil) {
        router.openEncryptor(with: key, issuedFor: nil)
    }

    /// The receiving window for the selected key — after the PIN, if the key is locked.
    ///
    /// Opening it never touches the key: the window finds the account by locator from what
    /// the panel has already read, and waits for its button. A link clicked in a browser
    /// lands here too, which is why that has to be so.
    func openDecryptor(prefilled message: SealedMessageURL? = nil) {
        guard let device = selectedDevice else {
            pendingIntent = .decrypt(message)
            setStatus("Plug in the security key this message was encrypted for")
            router.openPanelForIncomingLink()
            return
        }
        guard isSelectedKeyUnlocked else {
            pendingIntent = .decrypt(message)
            route = .unlock
            router.openPanelForIncomingLink()
            return
        }
        if let open = decryptor.store, decryptor.boundDevicePath == device.path {
            if let message { open.adopt(message) }
            router.openDecryptor(open)
        } else {
            let store = MessageDecryptStore(accounts: accounts,
                                            touchGate: touchGate,
                                            devicePath: device.path,
                                            deviceName: device.displayName,
                                            prefilled: message)
            decryptor.open(store, boundTo: device.path)
        }
        router.closePanel()
    }

    /// A `fidopass://` link from the system, already read. Opens a window with it, and
    /// nothing more — see `IncomingLink`.
    func handleLink(_ link: IncomingLink) {
        switch link {
        case .encryptionKey(let key):
            openEncryptor(with: key)
        case .sealedMessage(let message):
            openDecryptor(prefilled: message)
        case .unrecognised(let reason):
            setStatus("Not a FidoPass link — \(reason.localizedDescription.lowercased())")
            router.openPanelForIncomingLink()
        }
    }

    // MARK: - Touch prompt

    /// The panel's door to the key — `TouchGate`, with the prompt drawn here.
    func withTouchPrompt<T>(_ prompt: TouchPrompt, _ body: () async throws -> T) async throws -> T {
        let token = lifetime
        let value = try await touchGate.withTouchPrompt(prompt, surface: .panel, body)
        try KeyOperationContext.check(token)
        return value
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

    #if FIDOPASS_VIRTUAL_KEYS
    func openVirtualDevices() {
        router.openVirtualDevices()
    }
    #endif

    func quit() {
        router.quit()
    }

    /// A key stopped being usable. The container has already dropped what the other stores
    /// held for it; this is only what the panel itself was showing.
    func keyDidClose(_ path: String) {
        if devices.selectedPath == path || selection?.devicePath == path {
            lifetime.invalidate()
            lifetime = OperationLease()
            pinDraft = ""
            pinForm.clear()
            clearAccountFlow()
            if touchGate.surface == .panel { touchGate.abandonTouch() }
        }
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
        panelDidClose()
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

    func present(_ failure: Error) {
        guard !(failure is CancellationError) else { return }
        error = PresentedError(failure)
    }

    /// Presents an error, supplying the meaning of a bare refusal — see
    /// `PresentedError.init(_:meaningOfRefusal:)`.
    func present(_ failure: Error, whenRefused meaning: String) {
        guard !(failure is CancellationError) else { return }
        error = PresentedError(failure, meaningOfRefusal: meaning)
    }

    func setStatus(_ text: String) {
        statusText = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.statusText = nil
        }
    }

}
