@preconcurrency import FidoPassCore
import Foundation

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
    /// Fields of the set/change PIN screens. Separate from `pinDraft`, which is the unlock
    /// field: a half-typed new PIN must never be submitted as an unlock attempt.
    @Published var pinForm = PinForm()
    @Published private(set) var isWorking = false
    /// What the app is doing while it makes the user wait, when no key touch is involved.
    /// A touch has its own prompt; this covers the silent waits, above all PIN verification.
    @Published private(set) var busyTitle: String?
    /// Value being shown on the backup-key screen. Never persisted, dropped on leaving.
    @Published private(set) var backupKey: String?
    @Published var enrollDraft = EnrollDraft()
    /// The reset wizard, or nil when none is running.
    @Published var resetFlow: ResetFlow?
    @Published private(set) var enrollStep: String?
    /// Set while a system panel of our own is up — a save dialog takes key status away, and
    /// the HUD must not vanish behind it.
    @Published private(set) var isShowingSystemPanel = false
    /// True while the label is being typed rather than picked. Arrow keys belong to the text
    /// field then, not to the list behind it.
    @Published var isEditingLabel = false
    /// Where the caret goes when the arrows move focus into the custom field: at the end when
    /// arriving from the right, so the next press keeps moving in the same direction instead
    /// of bouncing straight back out.
    @Published private(set) var labelFieldCaretAtEnd = false

    /// A reset in progress.
    ///
    /// Reset is the one operation that destroys more than the delete screen does, and the key
    /// dictates its shape: most authenticators accept a reset only within seconds of power-up,
    /// so a physical reconnect is part of the flow rather than a nicety.
    struct ResetFlow: Equatable {
        enum Stage: Equatable {
            /// Reading what will be lost, and confirming it.
            case confirm
            /// "Unplug the key" — waiting for it to disappear.
            case unplug
            /// "Plug it back in" — the reset fires the instant it returns.
            case replug
            case running
        }

        struct Doomed: Equatable, Identifiable {
            let ref: AccountRef
            let kind: AccountKind
            var id: String { ref.accountId }
        }

        var stage: Stage = .confirm
        var deviceName: String
        /// Checked inside the reset itself, after the reconnect. A different AAGUID means a
        /// different key came back; a matching one proves nothing.
        var expectedAAGUID: String?
        /// What is on the key, when it could be read. A locked key cannot be enumerated — and
        /// a locked-out key is the most common reason to reset one — so this may be empty for
        /// a key that is anything but.
        var doomed: [Doomed]
        var accountsReadable: Bool
        /// Label histories to forget afterwards. Collected now: they are keyed by credential
        /// id, and after the reset there is nothing left to ask for one.
        var scopes: [LabelScope]
        var acknowledged = false
        var typed = ""

        var hasLocalAccounts: Bool { doomed.contains { $0.kind == .local } }

        /// A local account's passwords cannot be recovered by any means, so erasing one asks
        /// for more than a click. Portable accounts have a backup key; an unreadable key has
        /// nothing to enumerate and nothing to spell out.
        var requiresTypedConfirmation: Bool { hasLocalAccounts }

        /// Whether the key is *known* to hold nothing.
        ///
        /// An empty `doomed` is not the same as an empty key: a locked key cannot be
        /// enumerated, so the list is empty precisely when the contents are unknown. Waiving
        /// the acknowledgement on that would skip the warning in the one case where the user
        /// has the least idea what they are about to erase.
        var isKnownEmpty: Bool { doomed.isEmpty && accountsReadable }

        var canProceed: Bool {
            guard acknowledged || isKnownEmpty else { return false }
            guard requiresTypedConfirmation else { return true }
            return typed == "RESET"
        }
    }

    /// What the PIN screens are holding. Wiped on leaving them — see `panelDidClose`.
    struct PinForm: Equatable {
        var current: String = ""
        var new: String = ""
        var confirm: String = ""

        var isEmpty: Bool { current.isEmpty && new.isEmpty && confirm.isEmpty }

        mutating func clear() {
            current = ""
            new = ""
            confirm = ""
        }
    }

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
    /// What the manager window has read. Empty until that window asks for something.
    let inventory: InventoryStore
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
    /// Opens the FIDO manager window. A window, not a route: the panel is the wrong shape
    /// for it, and the manager has to survive the panel closing behind it.
    var onRequestOpenManager: (() -> Void)?
    /// Brings the panel up. Used by the manager window, which has no PIN field of its own —
    /// a second place to type a PIN is a second place to spend one of the eight attempts.
    var onRequestOpenPanel: (() -> Void)?
    /// Raised when the key state changes in a way the menu-bar icon must reflect.
    var onStateChanged: (() -> Void)?

    private var pendingIntent: HUDIntent?
    /// Device whose key the open editor session belongs to, or nil when no editor is open.
    private(set) var editorDevicePath: String?
    private var statusTask: Task<Void, Never>?
    /// The reset triggered by the key reappearing, while it runs.
    private(set) var resetTask: Task<Void, Never>?

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
        self.inventory = InventoryStore(backend: backend,
                                        pin: { [weak deviceStore] path in deviceStore?.pin(for: path) })
        self.labels = labels ?? LabelStore()
        self.preferences = settings

        settings.onLockTimeoutChanged = { [weak deviceStore] ttl in deviceStore?.setPinTTL(ttl) }
        generation.onClipboardChanged = { [weak self] in self?.onStateChanged?() }
        devices.onKeyClosed = { [weak self] path in self?.handleKeyClosed(path) }
        devices.onSessionLocked = { [weak self] in self?.handleSessionLocked() }
        devices.onDeviceListChanged = { [weak self] in self?.onStateChanged?() }
        devices.onArmedKeyAppeared = { [weak self] device in
            // Held so the work is reachable: the reset starts from a hot-plug callback, and
            // without a handle nothing — a test, or a later step of the wizard — can tell
            // whether it has finished.
            self?.resetTask = Task { @MainActor [weak self] in await self?.performArmedReset(on: device) }
        }
    }

    // MARK: - Derived state

    var selectedDevice: FidoDevice? { devices.selectedState?.device }
    var isSelectedKeyUnlocked: Bool { devices.selectedState?.unlocked == true }

    var visibleAccounts: [Account] {
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

    var snapshot: HUDSnapshot {
        HUDSnapshot(hasDevices: !devices.devices.isEmpty,
                    selectedDevicePath: devices.selectedPath,
                    isUnlocked: isSelectedKeyUnlocked,
                    keyHasPIN: devices.selectedState?.hasPIN,
                    accountRefs: visibleAccounts.compactMap(AccountRef.init),
                    selection: selection)
    }

    /// What `⏎` is expected to do in the current state.
    ///
    /// Read by the tests that pin the click budget, not by the panel: each screen owns its
    /// own default button, because a second, global Return handler used to fire alongside
    /// the focused field's submit and spend two PIN attempts on one keypress. This is the
    /// statement of what those buttons must add up to, checked against real store state.
    var primaryAction: HUDPrimaryAction { HUDReducer.primaryAction(snapshot) }

    /// What may actually be shown, given the state of the key.
    ///
    /// `route` is an intention; this is the truth. Deriving it here rather than trusting
    /// every code path to keep `route` in step is what stops the panel from claiming
    /// "no accounts on this key" under a header that says the key is locked — its account
    /// list is not empty, it is unread, and the two must never look the same.
    var effectiveRoute: HUDRoute {
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
        await readStatusOfLockedKey()
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
        pinForm.clear()
        errorText = nil
        backupKey = nil
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
        if case .backupKey = route {} else { backupKey = nil }
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
        case .enroll, .backupKey, .confirmDelete:
            return true
        }
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
        case .setPIN:
            // There is nowhere to go back to: every other screen needs a PIN this key has not
            // got. Escape closes the panel, as it does on the account list.
            return false
        case .pinChangeRequired:
            // Nowhere to go back to: the key refuses everything until the PIN is changed.
            return true
        case .enroll, .backupKey, .confirmDelete:
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

    // MARK: - PIN management

    /// The rules this key enforces on its own PIN.
    var pinPolicy: PinPolicy { devices.selectedState?.pinPolicy ?? PinPolicy() }

    /// Why the PIN being typed cannot be submitted yet — in words for the person typing.
    ///
    /// Judged here rather than by the key. For setting a first PIN that only changes *when*
    /// the user finds out, since libfido2 rejects a bad length before it sends anything. For
    /// a change it matters far more: a new PIN that was never going to be accepted must not
    /// cost one of the eight attempts standing between this key and a permanent lock-out.
    func pinFormIssue(forChange: Bool) -> String? {
        let old = forChange && !pinForm.current.isEmpty ? pinForm.current : nil
        if let issue = pinPolicy.validate(pinForm.new, oldPIN: old) {
            // "Enter a PIN" under an empty field is noise, not help.
            return issue == .empty ? nil : issue.message
        }
        if !pinForm.confirm.isEmpty, pinForm.new != pinForm.confirm {
            return "The two PINs do not match."
        }
        return nil
    }

    func canSubmitPinForm(forChange: Bool) -> Bool {
        guard !isWorking, pinFormIssue(forChange: forChange) == nil else { return false }
        guard !pinForm.new.isEmpty, pinForm.new == pinForm.confirm else { return false }
        return forChange ? !pinForm.current.isEmpty : true
    }

    /// Bootstrap: this key has never had a PIN.
    func setInitialPIN() async {
        // Return reaches here from the field and from the default button both.
        guard !isWorking, let device = selectedDevice, canSubmitPinForm(forChange: false) else { return }
        let newPIN = pinForm.new
        isWorking = true
        busyTitle = "Setting the PIN…"
        defer { busyTitle = nil }
        do {
            try await devices.setInitialPIN(for: device, newPIN: newPIN)
            pinForm.clear()
            errorText = nil
            await reloadAccountsIfNeeded()
            restoreSelectionIfNeeded()
            route = .accounts
            isWorking = false
            setStatus("PIN set — this key is ready to use")
            onStateChanged?()
            await runPendingIntentIfPossible()
        } catch {
            isWorking = false
            present(error, whenRefused: "This key already has a PIN. Use “Change PIN…” instead.")
        }
    }

    /// Replaces the PIN, having been told the current one.
    ///
    /// The current PIN is asked for even when it is sitting in the vault. It is the only thing
    /// standing between an unattended unlocked Mac and a key whose PIN its owner no longer
    /// knows — and this screen is reached about once a year, so the extra field costs nothing
    /// worth counting.
    func changePIN() async {
        guard !isWorking, let device = selectedDevice, canSubmitPinForm(forChange: true) else { return }
        let current = pinForm.current
        let newPIN = pinForm.new
        isWorking = true
        busyTitle = "Changing the PIN…"
        defer { busyTitle = nil }
        do {
            try await devices.changePIN(for: device, oldPIN: current, newPIN: newPIN)
            pinForm.clear()
            errorText = nil
            await reloadAccountsIfNeeded()
            restoreSelectionIfNeeded()
            route = .accounts
            isWorking = false
            setStatus("PIN changed — your passwords are unaffected")
            onStateChanged?()
            await runPendingIntentIfPossible()
        } catch {
            isWorking = false
            // Only the current PIN is cleared: retyping a new PIN that was fine is busywork,
            // and the failure was about the old one.
            pinForm.current = ""
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

    // MARK: - Reset

    /// Opens the reset wizard for the selected key.
    ///
    /// Refuses outright with more than one key connected. After the reconnect this flow needs,
    /// the path is different and a vendor signature only names a model — there is no way left
    /// to prove which key came back, and an operation that erases everything may not proceed
    /// on a guess.
    func beginReset() async {
        guard !isWorking, let device = selectedDevice else { return }
        guard devices.devices.count == 1 else {
            errorText = "Resetting works with one key connected. Unplug the others first — after the key is reconnected there is no way to tell two apart, and this erases everything on whichever one is there."
            return
        }
        // A user request, so opening the key here is allowed — and the AAGUID it returns is
        // the only thing that will notice a different key coming back.
        await devices.refreshStatus(for: device)

        let onKey = accounts.accounts(onDevice: device.path)
        let readable = isSelectedKeyUnlocked && devices.state(for: device.path)?.hasPIN != false
        resetFlow = ResetFlow(deviceName: device.displayName,
                              expectedAAGUID: devices.state(for: device.path)?.aaguid,
                              doomed: onKey.compactMap { account in
                                  AccountRef(account).map { ResetFlow.Doomed(ref: $0, kind: account.kind) }
                              },
                              accountsReadable: readable,
                              scopes: onKey.map { LabelScope(credentialId: $0.credentialIdB64) })
    }

    /// Confirmed. From here on the key is what drives the flow.
    func armReset() {
        guard var flow = resetFlow, flow.stage == .confirm, flow.canProceed else { return }
        flow.stage = .unplug
        resetFlow = flow
        devices.armReset(expectedAAGUID: flow.expectedAAGUID)
        errorText = nil
    }

    func cancelReset() {
        devices.disarmReset()
        resetFlow = nil
    }

    /// The key came back while a reset was armed. This runs on the millisecond, not after the
    /// usual refresh: the window in which most keys accept a reset is a few seconds wide.
    private func performArmedReset(on device: FidoDevice) async {
        guard var flow = resetFlow, flow.stage == .unplug || flow.stage == .replug else { return }
        devices.disarmReset()
        flow.stage = .running
        resetFlow = flow
        let scopes = flow.scopes

        do {
            try await withTouchPrompt(TouchPrompt(title: "Touch the key to confirm the reset",
                                                  message: "This erases everything on it. The key gives you about 30 seconds.",
                                                  deviceName: device.displayName)) {
                try await self.devices.resetKey(device, expectedAAGUID: flow.expectedAAGUID)
            }
            // The credential ids these histories are keyed by will never exist again, so the
            // histories would be orphaned for good. Everything else on the key was already
            // dropped by `adoptResetKey` closing it.
            for scope in scopes { labels.forget(scope) }
            preferences.forgetLastUsed()
            resetFlow = nil
            // The key now has no PIN, which is where `effectiveRoute` sends it — straight into
            // bootstrap. Leaving the user on an empty account list would be the dead end this
            // whole plan exists to remove.
            route = .accounts
            setStatus("Key erased — set a new PIN to use it")
            onStateChanged?()
        } catch {
            resetFlow?.stage = .replug
            present(error, whenRefused: "The key had already been awake too long — most keys only accept a reset in the first seconds after being plugged in. Unplug it and plug it back in to try again.")
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
        isShowingSystemPanel = true
        onRequestSaveRecoverySheet?(sheet)
    }

    func recoverySheetFinished(saved: Bool) {
        isShowingSystemPanel = false
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

    /// Sends the user to the panel's PIN field for a key the manager needs opened.
    func requestUnlock(devicePath: String) {
        devices.selectedPath = devicePath
        route = .accounts
        onRequestOpenPanel?()
    }

    /// Opens the manager window. Reads nothing by itself — the window asks first.
    func openManager() {
        onRequestOpenManager?()
        onRequestClose?()
    }

    private func handleKeyClosed(_ path: String) {
        // The wizard is waiting for exactly this: the key has gone, so the next thing to
        // happen is it coming back.
        if resetFlow?.stage == .unplug, devices.armedReset != nil {
            resetFlow?.stage = .replug
        }
        // An open editor holds a derived key for one of this key's accounts. Locking has to
        // take that with it, or "locked" would describe the account list while the secrets
        // stayed reachable in another window.
        closeEditor(ifBoundTo: path)
        accounts.drop(devicePath: path)
        generation.dropEverything(forDevicePath: path)
        // A key that merely locked keeps what it said about *itself* — that is public
        // information about the model — but loses its credential list, which names other
        // services' accounts. A key that was unplugged loses both: `DeviceStore` has already
        // removed its state by the time this runs, so its absence is the test.
        if devices.state(for: path) == nil {
            inventory.drop(devicePath: path)
        } else {
            inventory.dropInventory(devicePath: path)
        }
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
        inventory.dropAll()
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

    /// Presents an error, supplying the meaning of a bare refusal.
    ///
    /// `FIDO_ERR_NOT_ALLOWED` means "not in this state", and which state depends entirely on
    /// what was attempted — a PIN that already exists, a reset window that has closed. The
    /// status mapping cannot know that; the operation can.
    private func present(_ error: Error, whenRefused meaning: String) {
        let presented = FidoPassErrorPresenter.message(for: error)
        guard presented.kind == .notAllowed else {
            errorText = presented.fullText(retriesRemaining: devices.selectedState?.pinRetriesRemaining)
            return
        }
        errorText = [presented.title, meaning].joined(separator: "\n\n")
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
