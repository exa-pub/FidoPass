@preconcurrency import FidoPassCore
import Foundation

/// What the HUD is showing.
enum HUDRoute: Equatable {
    case accounts
    case unlock
    case enroll
    case backupKey(AccountRef)
    case confirmDelete(AccountRef)
    case keyInfo
}

/// The key is waiting to be touched.
struct TouchPrompt: Equatable {
    var title: String
    var message: String
    var deviceName: String
    var startedAt: Date = Date()
}

/// Why the HUD was opened. Survives the PIN prompt so that unlocking continues the thing the
/// user actually asked for instead of dropping them on a list.
enum HUDIntent: Equatable {
    case copyPassword(AccountRef, label: String)
    case revealPassword(AccountRef, label: String)
    case enroll
}

/// The single object the HUD views talk to.
///
/// It owns navigation, and it is the only place allowed to start an operation on the key —
/// which is what guarantees the touch prompt is always raised. A view reaching past it into
/// a store is a bug: that is exactly how the app once ended up looking frozen while the key
/// silently waited for a finger.
@MainActor
final class HUDStore: ObservableObject {

    @Published private(set) var route: HUDRoute = .accounts
    @Published private(set) var touch: TouchPrompt?
    @Published var errorText: String?
    @Published private(set) var statusText: String?
    @Published var selection: AccountRef?
    @Published var pinDraft: String = ""
    @Published private(set) var isWorking = false
    /// What the app is doing while it makes the user wait, when no key touch is involved.
    /// A touch has its own prompt; this covers the silent waits, above all PIN verification.
    @Published private(set) var busyTitle: String?
    /// Value being shown on the backup-key screen. Never persisted, dropped on leaving.
    @Published private(set) var backupKey: String?
    @Published var enrollDraft = EnrollDraft()
    @Published private(set) var enrollStep: String?
    /// Set while a system panel or a deliberate reading screen is up: the panel must not
    /// close under the user's hands.
    @Published private(set) var isPinnedOpen = false
    /// True while the label is being typed rather than picked. Arrow keys belong to the text
    /// field then, not to the list behind it.
    @Published var isEditingLabel = false
    /// Where the caret goes when the arrows move focus into the custom field: at the end when
    /// arriving from the right, so the next press keeps moving in the same direction instead
    /// of bouncing straight back out.
    @Published private(set) var labelFieldCaretAtEnd = false

    struct EnrollDraft: Equatable {
        var accountId: String = ""
        var kind: AccountKind = .portable
        var importedKeyB64: String = ""

        var trimmedId: String { accountId.trimmingCharacters(in: .whitespacesAndNewlines) }

        var importedKeyError: String? {
            guard !importedKeyB64.isEmpty else { return nil }
            guard let data = Data(base64Encoded: importedKeyB64), data.count == 32 else {
                return "Requires a 32-byte base64 value"
            }
            return nil
        }

        var canCreate: Bool { !trimmedId.isEmpty && importedKeyError == nil }
    }

    let devices: DeviceStore
    let accounts: AccountStore
    let generation: GenerationStore
    let labels: LabelStore
    let preferences: Preferences

    /// Asks the presenter to close the panel — after a copy, or when there is nothing left
    /// to do.
    var onRequestClose: (() -> Void)?
    var onRequestOpenEditor: ((CryptoEditorSession) -> Void)?
    /// Closes the text editor window. Its session holds a live key for one account, so every
    /// path that revokes access to that account has to take the window with it.
    var onRequestCloseEditor: (() -> Void)?
    var onRequestSaveRecoverySheet: ((RecoverySheet) -> Void)?
    /// Raised when the key state changes in a way the menu-bar icon must reflect.
    var onStateChanged: (() -> Void)?

    private var pendingIntent: HUDIntent?
    /// Device whose key the open editor session belongs to, or nil when no editor is open.
    private(set) var editorDevicePath: String?
    private var statusTask: Task<Void, Never>?

    /// The stores are built here rather than injected as defaults: a default argument is
    /// evaluated outside the main actor, and every one of these is main-actor bound.
    init(backend: KeyBackend = LiveKeyBackend(),
         preferences: Preferences? = nil,
         labels: LabelStore? = nil,
         emptyConfirmationDelay: Duration = .milliseconds(700),
         enableMonitors: Bool = true) {
        let settings = preferences ?? Preferences()
        let deviceStore = DeviceStore(backend: backend,
                                      pinTTL: settings.lockTimeout,
                                      emptyConfirmationDelay: emptyConfirmationDelay,
                                      enableMonitors: enableMonitors)
        self.devices = deviceStore
        self.accounts = AccountStore(backend: backend,
                                     pin: { [weak deviceStore] path in deviceStore?.pin(for: path) },
                                     pinProvider: { [weak deviceStore] path in deviceStore?.pinProvider(for: path) })
        self.generation = GenerationStore(backend: backend,
                                          pinProvider: { [weak deviceStore] path in deviceStore?.pinProvider(for: path) })
        self.labels = labels ?? LabelStore()
        self.preferences = settings

        settings.onLockTimeoutChanged = { [weak deviceStore] ttl in deviceStore?.setPinTTL(ttl) }
        generation.onClipboardChanged = { [weak self] in self?.onStateChanged?() }
        devices.onKeyClosed = { [weak self] path in self?.handleKeyClosed(path) }
        devices.onSessionLocked = { [weak self] in self?.handleSessionLocked() }
        devices.onDeviceListChanged = { [weak self] in self?.onStateChanged?() }
    }

    // MARK: - Derived state

    var selectedDevice: FidoDevice? { devices.selectedState?.device }
    var isSelectedKeyUnlocked: Bool { devices.selectedState?.unlocked == true }

    var visibleAccounts: [Account] {
        guard let path = devices.selectedPath else { return [] }
        return accounts.accounts(onDevice: path)
    }

    var selectedAccount: Account? {
        guard let selection else { return nil }
        return accounts.account(selection)
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

    var snapshot: HUDSnapshot {
        HUDSnapshot(hasDevices: !devices.devices.isEmpty,
                    selectedDevicePath: devices.selectedPath,
                    isUnlocked: isSelectedKeyUnlocked,
                    accountRefs: visibleAccounts.compactMap(AccountRef.init),
                    selection: selection)
    }

    var primaryAction: HUDPrimaryAction { HUDReducer.primaryAction(snapshot) }

    /// What may actually be shown, given the state of the key.
    ///
    /// `route` is an intention; this is the truth. Deriving it here rather than trusting
    /// every code path to keep `route` in step is what stops the panel from claiming
    /// "no accounts on this key" under a header that says the key is locked — its account
    /// list is not empty, it is unread, and the two must never look the same.
    var effectiveRoute: HUDRoute {
        guard !devices.devices.isEmpty else { return .accounts }
        guard isSelectedKeyUnlocked else {
            // Key info is read without a PIN and without a touch, so it stays available.
            if case .keyInfo = route { return .keyInfo }
            return .unlock
        }
        return route
    }

    /// State the menu-bar icon renders.
    var iconState: StatusItemIcon.State {
        if touch != nil { return .waitingForTouch }
        if devices.devices.isEmpty { return .noKey }
        if generation.receipt?.clearsAt != nil { return .clipboardHot }
        return isSelectedKeyUnlocked ? .unlocked : .locked
    }

    // MARK: - Lifecycle

    /// Called every time the panel is about to appear.
    func prepareForDisplay(intent: HUDIntent? = nil) async {
        errorText = nil
        await devices.refresh()
        if let failure = devices.refreshError { errorText = failure }
        await reloadAccountsIfNeeded()
        restoreSelectionIfNeeded()

        if let intent {
            pendingIntent = intent
        }
        route = isSelectedKeyUnlocked ? .accounts : (devices.devices.isEmpty ? .accounts : .unlock)
        if isSelectedKeyUnlocked { await runPendingIntentIfPossible() }
        onStateChanged?()
    }

    func panelDidClose() {
        pinDraft = ""
        errorText = nil
        backupKey = nil
        enrollStep = nil
        if case .accounts = route {} else { route = .accounts }
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
            errorText = failure
        }
    }

    private func restoreSelectionIfNeeded() {
        let visible = visibleAccounts
        let resolved = selection.flatMap { visible.contains(where: $0.matches) ? $0 : nil }
            ?? HUDReducer.resolveSelection(accounts: visible,
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
                           deviceSignature: Preferences.signature(for: state.device),
                           deviceName: state.device.displayName)
    }

    private func focusLabels(on ref: AccountRef?) {
        labels.focus(labelTarget(for: ref))
        labels.current = HUDReducer.resolveLabel(recent: labels.recent)
    }

    // MARK: - Navigation

    func show(_ route: HUDRoute) {
        self.route = route
        isPinnedOpen = route.holdsPanelOpen
        if case .backupKey = route {} else { backupKey = nil }
    }

    func backToAccounts() {
        show(.accounts)
        errorText = nil
    }

    func select(_ ref: AccountRef) {
        selection = ref
        // The label moves with the account, so the result is judged against the new label —
        // otherwise a password derived from the previous one would stay on screen under an
        // account it does not belong to.
        focusLabels(on: ref)
        generation.invalidateResult(unless: ref, label: labels.current)
    }

    /// Moves the selection by one row. Clamped rather than wrapping: with two or three
    /// accounts, silently jumping from the last to the first is a way to derive the wrong
    /// password without noticing.
    func moveSelection(by offset: Int) {
        let refs = visibleAccounts.compactMap(AccountRef.init)
        guard !refs.isEmpty else { return }
        let current = selection.flatMap { refs.firstIndex(of: $0) } ?? 0
        let next = min(max(current + offset, 0), refs.count - 1)
        guard next != current || selection == nil else { return }
        select(refs[next])
    }

    /// Walks the label row: chip, chip, …, and then the custom field.
    ///
    /// The field is a position like any other, so the arrows reach it instead of stopping at
    /// the last chip. It is the last one, and once inside, the caret decides — the field
    /// itself only hands control back when the caret is already at the start.
    func moveLabelFocus(by offset: Int) {
        let chips = labels.chips
        let fieldIndex = chips.count          // the custom field is the last position
        let count = fieldIndex + 1
        guard count > 1 else { return }

        // Standing on the field means either typing in it, or having a label that is not one
        // of the chips — that text lives there whether or not it has focus.
        let current = isEditingLabel || !chips.contains(labels.current)
            ? fieldIndex
            : (chips.firstIndex(of: labels.current) ?? 0)

        // Wraps: with three or four positions, a dead end at each edge is just a key that
        // does nothing.
        let next = (current + offset + count) % count
        guard next != current || offset == 0 else { return }

        if next == fieldIndex {
            labelFieldCaretAtEnd = offset < 0
            isEditingLabel = true
        } else {
            isEditingLabel = false
            setLabel(chips[next])
        }
    }

    func selectAccount(at index: Int) {
        let refs = visibleAccounts.compactMap(AccountRef.init)
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
        labels.current = label
        if let selection { generation.invalidateResult(unless: selection, label: label) }
    }

    /// Escape: leave the screen, not the app.
    ///
    /// - Returns: true when the store handled it; false means the panel should close.
    func handleEscape() -> Bool {
        if isEditingLabel {
            isEditingLabel = false
            return true
        }
        switch route {
        case .accounts, .unlock:
            return false
        case .enroll, .backupKey, .confirmDelete, .keyInfo:
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
        case .enroll:
            return ["⏎ create", "esc cancel"]
        case .backupKey, .keyInfo:
            return ["esc back"]
        case .confirmDelete:
            return ["esc cancel"]
        case .accounts:
            guard !devices.devices.isEmpty else { return [] }
            guard !visibleAccounts.isEmpty else { return ["⌘N new account"] }
            if isEditingLabel { return ["⏎ copy", "esc done"] }
            var hints = ["⏎ copy", "⌘⏎ show"]
            if visibleAccounts.count > 1 { hints.append("↑↓ account") }
            if !labels.chips.isEmpty { hints.append("←→ label") }
            hints.append("⌘N new")
            return hints
        }
    }

    // MARK: - The primary action

    func runPrimaryAction() async {
        switch primaryAction {
        case .connectKey:
            await devices.refresh()
        case .unlock:
            await submitPin()
        case .createAccount:
            show(.enroll)
        case .chooseAccount:
            restoreSelectionIfNeeded()
        case .generateAndCopy(let ref):
            await copyPassword(for: ref)
        }
    }

    // MARK: - Unlock

    func submitPin() async {
        // A PIN attempt is a scarce resource: eight consecutive failures kill the key for
        // good. Return can reach here twice — the field's submit action and the default
        // button — and two attempts must never be spent on one keypress.
        guard !isWorking else { return }
        guard let device = selectedDevice, !pinDraft.isEmpty else { return }
        let pin = pinDraft
        isWorking = true
        busyTitle = "Checking the PIN…"
        defer { busyTitle = nil }
        do {
            try await devices.unlock(device, pin: pin)
            pinDraft = ""
            errorText = nil
            await reloadAccountsIfNeeded()
            restoreSelectionIfNeeded()
            // Only the PIN screen is replaced: a screen requested while the key was locked
            // (⌘N, say) is still what the user is waiting for.
            if route == .unlock { route = .accounts }
            // Released before the queued action runs: that action is an operation in its own
            // right, and it has to pass the same guard as if the user had asked for it now.
            isWorking = false
            onStateChanged?()
            await runPendingIntentIfPossible()
        } catch {
            isWorking = false
            pinDraft = ""
            let presented = FidoPassErrorPresenter.message(for: error)
            errorText = presented.fullText(retriesRemaining: devices.selectedState?.pinRetriesRemaining)
        }
    }

    func lockSelectedKey() {
        guard let path = devices.selectedPath else { return }
        devices.lock(path: path)
        onStateChanged?()
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
    func requestIntent(_ intent: HUDIntent) {
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
            requestIntent(reveal ? .revealPassword(ref, label: label ?? labels.current)
                                 : .copyPassword(ref, label: label ?? labels.current))
            route = .unlock
            return
        }
        let usedLabel = (label ?? labels.current).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !usedLabel.isEmpty else {
            errorText = "Enter a label first — it is part of the derivation."
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
                try await self.generation.generate(account: account, label: usedLabel)
            }
            if let target = labelTarget(for: ref) { labels.use(usedLabel, in: target) }
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
            onStateChanged?()
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
        onStateChanged?()
    }

    // MARK: - Enrolment

    func createAccount() async {
        guard !isWorking else { return }
        guard enrollDraft.canCreate,
              let path = devices.selectedPath,
              let device = selectedDevice else { return }
        let draft = enrollDraft
        let imported = draft.importedKeyB64.isEmpty ? nil : draft.importedKeyB64

        do {
            let created = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                                message: draft.kind == .portable
                                                                    ? "Step 1 of 2 — creating the credential."
                                                                    : "Confirming with the key.",
                                                                deviceName: device.displayName)) {
                try await self.accounts.enroll(accountId: draft.trimmedId,
                                               kind: draft.kind,
                                               devicePath: path,
                                               importedKeyB64: imported) { step in
                    Task { @MainActor in self.enrollStep = Self.stepMessage(step) }
                }
            }
            enrollStep = nil
            enrollDraft = EnrollDraft()
            if let ref = AccountRef(created.0) { select(ref) }

            if let backup = created.1 {
                // Shown on its own screen, never in a field that reads like a password:
                // this value reproduces every password of the account without the key.
                backupKey = backup
                show(.backupKey(AccountRef(accountId: draft.trimmedId, devicePath: path)))
            } else {
                show(.accounts)
                setStatus("Account added")
            }
            onStateChanged?()
        } catch {
            enrollStep = nil
            present(error)
        }
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
        isWorking = true
        busyTitle = "Deleting “\(ref.accountId)”…"
        defer { isWorking = false; busyTitle = nil }
        do {
            try await accounts.delete(account)
            if let scope { labels.forget(scope) }
            generation.clearResult()
            if selection == ref { selection = nil }
            restoreSelectionIfNeeded()
            show(.accounts)
            setStatus("Account deleted")
            onStateChanged?()
        } catch {
            present(error)
        }
    }

    // MARK: - Backup key and recovery

    func showBackupKey(for ref: AccountRef) async {
        guard !isWorking else { return }
        guard let account = accounts.account(ref), account.kind == .portable else { return }
        do {
            let key = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                            message: "Recovering the backup key.",
                                                            deviceName: selectedDevice?.displayName ?? "Security key")) {
                try await self.accounts.exportBackupKey(for: account)
            }
            backupKey = key
            show(.backupKey(ref))
        } catch {
            present(error)
        }
    }

    func copyBackupKey() {
        guard let key = backupKey, case .backupKey(let ref) = route else { return }
        generation.copy(key, as: .backupKey, for: ref)
        setStatus("Backup key copied — store it offline, not in a password manager")
    }

    func saveRecoverySheet(for ref: AccountRef) {
        guard let account = accounts.account(ref) else { return }
        let description = devices.state(for: ref.devicePath).map { "\($0.device.displayName) — \($0.device.identityLabel)" }
        let known = labelTarget(for: ref).map { labels.labels(for: $0.scope) } ?? []
        let sheet = RecoverySheet(account: account,
                                  labels: known,
                                  deviceDescription: description)
        isPinnedOpen = true
        onRequestSaveRecoverySheet?(sheet)
    }

    func recoverySheetFinished(saved: Bool) {
        isPinnedOpen = route.holdsPanelOpen
        if saved { setStatus("Recovery sheet saved — it contains no secrets") }
    }

    // MARK: - Text encryption

    func openEncryptEditor(for ref: AccountRef) async {
        guard !isWorking else { return }
        guard let account = accounts.account(ref) else { return }
        let label = labels.current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            errorText = "Enter a label first — the key is derived from it."
            return
        }
        do {
            let key = try await withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                            message: "Deriving the key for this editing session.",
                                                            deviceName: selectedDevice?.displayName ?? "Security key")) {
                try await self.accounts.deriveEncryptionKey(for: account, label: label)
            }
            if let target = labelTarget(for: ref) { labels.use(label, in: target) }
            let session = CryptoEditorSession(account: account, label: label, key: key, core: .shared)
            editorDevicePath = ref.devicePath
            onRequestOpenEditor?(session)
            onRequestClose?()
        } catch {
            present(error)
        }
    }

    // MARK: - Touch prompt

    /// The one door to the key.
    ///
    /// Every operation that makes the authenticator wait for a finger goes through here, so
    /// the prompt cannot be forgotten by a caller that is in a hurry.
    func withTouchPrompt<T>(_ prompt: TouchPrompt, _ body: @escaping () async throws -> T) async rethrows -> T {
        touch = prompt
        isWorking = true
        onStateChanged?()
        defer {
            touch = nil
            isWorking = false
            onStateChanged?()
        }
        return try await body()
    }

    /// Hides the prompt and abandons the result.
    ///
    /// libfido2 exposes `fido_dev_cancel`, but the repository does not surface the handle,
    /// so the operation itself finishes in the background — its result is simply discarded
    /// and never reaches the clipboard.
    func abandonTouch() {
        touch = nil
        isWorking = false
        onStateChanged?()
    }

    // MARK: - Housekeeping

    private func handleKeyClosed(_ path: String) {
        // An open editor holds a derived key for one of this key's accounts. Locking has to
        // take that with it, or "locked" would describe the account list while the secrets
        // stayed reachable in another window.
        closeEditor(ifBoundTo: path)
        accounts.drop(devicePath: path)
        generation.dropEverything(forDevicePath: path)
        if selection?.devicePath == path {
            selection = nil
            focusLabels(on: nil)
        }
        // The backup key on screen was derived from the key that just went away; it must not
        // outlive it, and there is nothing to come back to.
        if case .backupKey = route {
            backupKey = nil
            route = .accounts
        }
        onStateChanged?()
    }

    private func handleSessionLocked() {
        closeEditor(ifBoundTo: nil)
        backupKey = nil
        // The user walked away: an editing session left open would keep both the key and the
        // plaintext on screen behind the lock screen, and a copied password would still be
        // on the clipboard.
        generation.clearClipboard()
        generation.dropEverything()
        accounts.dropAll()
        selection = nil
        focusLabels(on: nil)
        route = .unlock
        onRequestClose?()
        onStateChanged?()
    }

    /// Closes the editor when it belongs to `path` — or unconditionally when `path` is nil.
    func closeEditor(ifBoundTo path: String?) {
        guard editorDevicePath != nil else { return }
        if let path, editorDevicePath != path { return }
        editorDevicePath = nil
        onRequestCloseEditor?()
    }

    func editorWindowClosed() {
        editorDevicePath = nil
    }

    func refresh() async {
        await devices.refresh()
        if let failure = devices.refreshError { errorText = failure }
        await reloadAccountsIfNeeded()
        restoreSelectionIfNeeded()
        onStateChanged?()
    }

    private func present(_ error: Error) {
        errorText = FidoPassErrorPresenter.message(for: error).fullText()
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

private extension HUDRoute {
    /// Screens the panel must not close under: the user is reading or typing something they
    /// cannot get back with one click.
    var holdsPanelOpen: Bool {
        switch self {
        case .accounts, .unlock: return false
        case .enroll, .backupKey, .confirmDelete, .keyInfo: return true
        }
    }
}
