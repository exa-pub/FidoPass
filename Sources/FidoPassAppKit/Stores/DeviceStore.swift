import FidoPassCore
import Foundation

/// Connected authenticators and their lock state.
///
/// Owns the PIN vault, the hot-plug watcher and the session-lock watcher: everything whose
/// lifetime is "as long as a key is plugged in and unlocked". Nothing here knows about
/// accounts — losing a key notifies, and the account side reacts.
@MainActor
final class DeviceStore: ObservableObject {

    struct KeyState: Equatable {
        let device: FidoDevice
        var unlocked: Bool = false
        var pinToken: SecurePinVault.Token?
        var pinGeneration = UUID()
        /// Whether the key has a PIN at all.
        ///
        /// `nil` means the key has not been asked yet — which is emphatically not "no PIN".
        /// Routing an unasked key to the bootstrap screen would offer to set a PIN on a key
        /// that already has one, and the key refuses that request.
        var hasPIN: Bool?
        /// PIN attempts the authenticator says are left, or `nil` when it declines to say.
        ///
        /// Never render `nil` as reassurance: eight consecutive failures lock the key for
        /// good, and for a vault master password there is no way back from that.
        var pinRetriesRemaining: Int?
        /// Shortest PIN this key accepts, when it says so.
        var minPINLength: Int?
        /// The key will do nothing else until the PIN is changed.
        var forcePINChange: Bool = false
        /// Make and model, not identity. Used only to notice that a *different* key came back
        /// after a reconnect — see `DeviceStatus.aaguid`.
        var aaguid: String?
        /// Whether the key has a large-blob store, which every new account's record needs.
        /// `nil` until the key has been asked; only a definite `false` closes anything.
        var supportsLargeBlobs: Bool?

        /// The rules to enforce in a PIN field for this key.
        var pinPolicy: PinPolicy { PinPolicy(minimumCodePoints: minPINLength ?? PinPolicy.ctapFloor) }
    }

    @Published private(set) var devices: [FidoDevice] = []
    @Published private(set) var states: [String: KeyState] = [:]
    @Published private(set) var isRefreshing = false
    /// Set when the last enumeration failed. Distinct from "no devices": the difference is
    /// the whole point.
    @Published private(set) var refreshError: PresentedError?
    /// Which key the HUD is pointed at. Only meaningful with more than one connected.
    @Published var selectedPath: String?

    /// Fired when a key stops being usable — locked, PIN expired, unplugged. The argument
    /// is the device path whose accounts and results must now be dropped.
    var onKeyClosed: ((String) -> Void)?
    /// Fired when the machine's session locks; everything derived must go with it.
    var onSessionLocked: (() -> Void)?

    private var leases: [String: OperationLease] = [:]
    func lease(for path: String) -> OperationLease {
        if let token = leases[path] { return token }
        let token = OperationLease()
        leases[path] = token
        return token
    }
    private func invalidate(_ path: String) { leases.removeValue(forKey: path)?.invalidate() }

    private var pendingRefresh = false
    private let worker: KeyWorker
    private let pinVault: SecurePinVault
    /// How long the PIN stays in the vault without being used. Settable: the user can change
    /// it in Preferences while a key is already unlocked.
    private(set) var pinTTL: TimeInterval
    /// How long to wait before believing that a key which was here a moment ago is gone.
    private let emptyConfirmationDelay: Duration
    private var deviceMonitor: DeviceMonitorService?
    private var sessionMonitor: SessionLockMonitor?

    init(worker: KeyWorker,
         pinVault: SecurePinVault = SecurePinVault(defaultTTL: 300),
         pinTTL: TimeInterval = 300,
         emptyConfirmationDelay: Duration = .milliseconds(700),
         enableMonitors: Bool = true) {
        self.worker = worker
        self.pinVault = pinVault
        self.pinTTL = pinTTL
        self.emptyConfirmationDelay = emptyConfirmationDelay
        guard enableMonitors else { return }
        deviceMonitor = DeviceMonitorService { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        sessionMonitor = SessionLockMonitor { [weak self] in
            Task { @MainActor in self?.handleSessionLock() }
        }
    }

    deinit {
        pinVault.removeAll()
    }

    var unlockedPaths: [String] {
        states.values.filter(\.unlocked).map(\.device.path)
    }

    func state(for path: String) -> KeyState? { states[path] }

    /// Applies a new timeout, to keys already unlocked as well as future ones.
    ///
    /// The live tokens are re-armed rather than left on the old deadline: shortening the
    /// timeout is something a user does because they want the key to lock sooner, and
    /// "sooner, starting with the next unlock" is not what they asked for.
    func setPinTTL(_ ttl: TimeInterval) {
        guard ttl > 0, ttl != pinTTL else { return }
        pinTTL = ttl
        for state in states.values {
            guard let token = state.pinToken else { continue }
            pinVault.extend(token: token, ttl: ttl)
        }
    }

    var selectedState: KeyState? {
        guard let selectedPath else { return nil }
        return states[selectedPath]
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else {
            // The event that arrived mid-refresh is the interesting one: it is a key being
            // plugged in or pulled out. Remember it and re-run once.
            pendingRefresh = true
            return
        }
        isRefreshing = true
        await performRefresh()
        isRefreshing = false

        if pendingRefresh {
            pendingRefresh = false
            await refresh()
        }
    }

    private func performRefresh() async {
        let listed: [FidoDevice]
        do {
            listed = try await worker.device { try $0.listDevices() }
        } catch {
            // An enumeration error does not prove disconnection; retain sessions and accounts.
            refreshError = PresentedError(error)
            return
        }

        // A key that has just been touched drops off the HID registry for a moment while it
        // re-enumerates, and one empty read in that window is noise, not an unplug. Confirm
        // before believing it.
        if listed.isEmpty, !devices.isEmpty {
            try? await Task.sleep(for: emptyConfirmationDelay)
            let confirmation: [FidoDevice]
            do {
                confirmation = try await worker.device { try $0.listDevices() }
            } catch {
                refreshError = PresentedError(error)
                return
            }
            let confirmed = confirmation
            guard confirmed.isEmpty else {
                refreshError = nil
                apply(confirmed)
                return
            }
        }

        refreshError = nil
        apply(listed)
    }

    private func apply(_ list: [FidoDevice]) {
        let sorted = list.sorted { lhs, rhs in
            lhs.identitySeed == rhs.identitySeed ? lhs.path < rhs.path : lhs.identitySeed < rhs.identitySeed
        }
        let previous = states
        var updated: [String: KeyState] = [:]
        for device in sorted {
            let old = previous[device.path]
            updated[device.path] = KeyState(device: device,
                                            unlocked: old?.unlocked ?? false,
                                            pinToken: old?.pinToken,
                                            pinGeneration: old?.pinGeneration ?? UUID(),
                                            hasPIN: old?.hasPIN,
                                            pinRetriesRemaining: old?.pinRetriesRemaining,
                                            minPINLength: old?.minPINLength,
                                            forcePINChange: old?.forcePINChange ?? false,
                                            aaguid: old?.aaguid,
                                            supportsLargeBlobs: old?.supportsLargeBlobs)
        }

        // A key that vanished takes its state with it, which would strand its vault token
        // while the PIN itself stayed in memory until the TTL expired. Release it here.
        let vanished = Set(previous.keys).subtracting(updated.keys)
        for path in vanished {
            invalidate(path)
            if let token = previous[path]?.pinToken { pinVault.remove(token: token) }
        }

        devices = sorted
        states = updated

        for path in vanished { onKeyClosed?(path) }

        if let current = selectedPath, updated[current] == nil { selectedPath = nil }
        if selectedPath == nil { selectedPath = sorted.first?.path }

        // A key reappearing while a reset is armed is handled before anything else gets a
        // chance to open it. The reset window is seconds wide, and the identity of what came
        // back cannot be proven from a path — so this only fires when exactly one key is
        // present, and the AAGUID check inside the reset itself does the rest.
        let appeared = Set(updated.keys).subtracting(previous.keys)
        if armedReset != nil, sorted.count == 1, let path = appeared.first,
           let device = updated[path]?.device {
            onArmedKeyAppeared?(device)
        }
    }

    // MARK: - Unlock / lock

    /// Verifies the PIN by asking the key to enumerate, then keeps it in the vault.
    ///
    /// Enumerating is the cheapest operation that actually exercises the PIN: it needs no
    /// touch, so a wrong PIN costs the user nothing but the attempt itself.
    func unlock(_ device: FidoDevice, pin: String) async throws {
        if let issue = PinPolicy.validateExisting(pin) { throw FidoPassError.invalidState(issue.message) }
        let path = device.path
        let token = lease(for: path)
        do {
            _ = try await worker.accounts(validity: token) { try $0.enumerateAccounts(devicePath: path, pin: pin) }
        } catch {
            try KeyOperationContext.check(token)
            await recordUnlockFailure(error, for: device, rejectedPIN: pin)
            throw error
        }

        try KeyOperationContext.check(token)
        guard var state = states[path] else { throw CancellationError() }
        if let existing = state.pinToken { pinVault.remove(token: existing) }
        state.pinGeneration = UUID()
        let generation = state.pinGeneration
        state.pinToken = pinVault.store(pin: pin, ttl: pinTTL) { [weak self] in
            Task { @MainActor in
                guard self?.states[path]?.pinGeneration == generation else { return }
                self?.handlePinExpiration(for: path)
            }
        }
        state.unlocked = true
        state.hasPIN = true
        state.pinRetriesRemaining = nil
        states[path] = state
    }

    // MARK: - Key management

    /// Gives a key with no PIN its first one, and treats the key as open from then on.
    ///
    /// The PIN goes straight into the vault: the user has just proved they know it by
    /// choosing it, and asking for it again on the next screen reads as "it did not hear me".
    func setInitialPIN(for device: FidoDevice, newPIN: String) async throws {
        let path = device.path
        let token = lease(for: path)
        try await worker.admin(validity: token) { try $0.setInitialPIN(devicePath: path, newPIN: newPIN) }
        try KeyOperationContext.check(token)
        adoptChangedPIN(path: path, newPIN: newPIN)
    }

    /// Replaces the PIN, and adopts the new one only if the key accepted it.
    ///
    /// On failure the vault is left alone. A typo in this form must not cost access that the
    /// old PIN still grants.
    func changePIN(for device: FidoDevice, oldPIN: String, newPIN: String) async throws {
        let path = device.path
        let token = lease(for: path)
        do {
            try await worker.admin(validity: token) { try $0.changePIN(devicePath: path, oldPIN: oldPIN, newPIN: newPIN) }
        } catch {
            try KeyOperationContext.check(token)
            await recordUnlockFailure(error, for: device, rejectedPIN: oldPIN)
            throw error
        }
        try KeyOperationContext.check(token)
        adoptChangedPIN(path: path, newPIN: newPIN)
    }

    /// Erases the key. Everything the app knew about it stops being true at this point.
    func resetKey(_ device: FidoDevice, expectedAAGUID: String?) async throws {
        let path = device.path
        let token = lease(for: path)
        try await worker.admin(validity: token) { try $0.resetDevice(devicePath: path, expectedAAGUID: expectedAAGUID) }
        try KeyOperationContext.check(token)
        adoptResetKey(path: path)
    }

    // MARK: - Authenticator settings

    /// CTAP 2.1 `authenticatorConfig`. Grouped with the PIN operations because these change
    /// the key itself, not what is stored on it — and, like a PIN change, they need the PIN
    /// and no touch (verified on hardware, ~0.15 s each).
    ///
    /// Two of the four cannot be undone, which is the caller's problem to make plain before
    /// getting here: this layer just performs them.
    private func authenticatedAdmin<T: Sendable>(path: String, token: OperationLease,
                                                _ body: @escaping @Sendable (KeyAdminBackend) throws -> T) async throws -> T {
        do { return try await worker.admin(validity: token, body) }
        catch {
            try KeyOperationContext.check(token)
            if KeyFailurePolicy.invalidatesPINSession(error) { lock(path: path) }
            throw error
        }
    }

    @discardableResult
    func toggleAlwaysUV(for device: FidoDevice) async throws -> Bool {
        let path = device.path
        let token = lease(for: path)
        guard let pin = pin(for: path) else { throw KeyLockedError() }
        return try await authenticatedAdmin(path: path, token: token) { try $0.toggleAlwaysUV(devicePath: path, pin: pin) }
    }

    func setMinimumPINLength(for device: FidoDevice, length: Int) async throws {
        let path = device.path
        let token = lease(for: path)
        guard let pin = pin(for: path) else { throw KeyLockedError() }
        try await authenticatedAdmin(path: path, token: token) { try $0.setMinimumPINLength(devicePath: path, length: length, pin: pin) }
        // The key may now consider the PIN in use too short, and it will refuse everything
        // else until that is dealt with. Re-read rather than assume.
        await refreshStatus(for: device)
    }

    func forcePINChange(for device: FidoDevice) async throws {
        let path = device.path
        let token = lease(for: path)
        guard let pin = pin(for: path) else { throw KeyLockedError() }
        try await authenticatedAdmin(path: path, token: token) { try $0.forcePINChange(devicePath: path, pin: pin) }
        // The key now refuses every other operation, and the HUD routes on exactly this flag.
        await refreshStatus(for: device)
    }

    func enableEnterpriseAttestation(for device: FidoDevice) async throws {
        let path = device.path
        let token = lease(for: path)
        guard let pin = pin(for: path) else { throw KeyLockedError() }
        try await authenticatedAdmin(path: path, token: token) { try $0.enableEnterpriseAttestation(devicePath: path, pin: pin) }
    }

    // MARK: - Armed reset

    /// A reset waiting for the key to be plugged back in.
    ///
    /// Most keys accept a reset only within a few seconds of power-up, so the flow has to run
    /// the moment the key reappears — not after the usual refresh has finished deciding what
    /// changed.
    struct ArmedReset: Equatable {
        let expectedAAGUID: String?
        let armedAt: Date
    }

    @Published private(set) var armedReset: ArmedReset?
    /// Fired when the key comes back while a reset is armed. The argument is the device to
    /// reset, and the caller has milliseconds to spare, not seconds.
    var onArmedKeyAppeared: ((FidoDevice) -> Void)?

    var onResetArmingExpired: (() -> Void)?
    private var disarmTask: Task<Void, Never>?

    /// Arms the reset and starts the window in which a reappearing key will be reset.
    ///
    /// Disarms itself after `timeout`: an arming that outlived the panel would fire on a key
    /// brought out for something else entirely, and erase it.
    func armReset(expectedAAGUID: String?, timeout: Duration = .seconds(60)) {
        armedReset = ArmedReset(expectedAAGUID: expectedAAGUID, armedAt: Date())
        disarmTask?.cancel()
        disarmTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.disarmReset()
                self?.onResetArmingExpired?()
            }
        }
    }

    func disarmReset() {
        disarmTask?.cancel()
        disarmTask = nil
        armedReset = nil
    }

    /// Replaces the cached PIN after a successful change, keeping the session unlocked.
    func adoptChangedPIN(path: String, newPIN: String) {
        guard var state = states[path] else { return }
        if let existing = state.pinToken { pinVault.remove(token: existing) }
        state.pinGeneration = UUID()
        let generation = state.pinGeneration
        state.pinToken = pinVault.store(pin: newPIN, ttl: pinTTL) { [weak self] in
            Task { @MainActor in
                guard self?.states[path]?.pinGeneration == generation else { return }
                self?.handlePinExpiration(for: path)
            }
        }
        state.unlocked = true
        state.hasPIN = true
        state.forcePINChange = false
        state.pinRetriesRemaining = nil
        states[path] = state
    }

    /// Forgets everything known about a key that has just been erased.
    ///
    /// A reset key has no PIN, no credentials and a full retry budget. Carrying any of the
    /// old state forward would leave the app describing a key that no longer exists.
    func adoptResetKey(path: String) {
        invalidate(path)
        guard var state = states[path] else { return }
        if let token = state.pinToken { pinVault.remove(token: token) }
        state.pinToken = nil
        state.unlocked = false
        state.hasPIN = false
        state.forcePINChange = false
        state.pinRetriesRemaining = nil
        states[path] = state
        onKeyClosed?(path)
    }

    private func recordUnlockFailure(_ error: Error, for device: FidoDevice, rejectedPIN: String) async {
        let path = device.path
        let token = lease(for: path)
        let presented = FidoPassErrorPresenter.message(for: error)
        var remaining: Int?
        if presented.kind == .pinInvalid {
            remaining = (try? await worker.device(validity: token) { try $0.status(devicePath: path).pinRetriesRemaining }) ?? nil
        }
        guard token.isValid, var state = states[path] else { return }
        switch presented.kind {
        case .pinInvalid: state.pinRetriesRemaining = remaining
        case .pinBlocked, .pinAuthBlocked: state.pinRetriesRemaining = 0
        default: return
        }
        let rejectedCachedPIN = state.pinToken.flatMap { pinVault.pin(for: $0) }
            .map { $0.utf8.elementsEqual(rejectedPIN.utf8) } ?? false
        let blocked = presented.kind == .pinBlocked || presented.kind == .pinAuthBlocked
        if rejectedCachedPIN || blocked {
            if let existing = state.pinToken { pinVault.remove(token: existing) }
            state.pinToken = nil
            state.unlocked = false
        }
        states[path] = state
        if rejectedCachedPIN || blocked {
            invalidate(path)
            onKeyClosed?(path)
        }
    }

    func lock(path: String) {
        invalidate(path)
        guard var state = states[path] else { return }
        if let token = state.pinToken { pinVault.remove(token: token) }
        state.unlocked = false
        state.pinToken = nil
        states[path] = state
        onKeyClosed?(path)
    }

    func lockAll() {
        for path in Array(states.keys) { lock(path: path) }
    }

    private func handlePinExpiration(for path: String) {
        guard states[path]?.unlocked == true else { return }
        lock(path: path)
    }

    private func handleSessionLock() {
        lockAll()
        onSessionLocked?()
    }

    // MARK: - PIN access

    func pin(for path: String) -> String? {
        guard let token = states[path]?.pinToken else { return nil }
        guard let pin = pinVault.pin(for: token, extending: pinTTL) else {
            handlePinExpiration(for: path)
            return nil
        }
        return pin
    }

    /// A closure the core can call to re-read the PIN mid-operation, without the store
    /// having to stay alive on the main actor while the key is being touched.
    func pinProvider(for path: String) -> (@Sendable () -> String?)? {
        guard let token = states[path]?.pinToken else { return nil }
        let vault = pinVault
        let ttl = pinTTL
        return { vault.pin(for: token, extending: ttl) }
    }

    func adoptInfo(_ info: AuthenticatorInfo, for path: String) {
        guard var state = states[path] else { return }
        state.minPINLength = info.minPINLength
        state.forcePINChange = info.forcePINChange
        state.hasPIN = info.option("clientPin")
        states[path] = state
    }

    /// Reads what the key says about itself: PIN attempts left, whether it has a PIN at all.
    ///
    /// Costs no PIN and no touch — but it does **open** the device, and on macOS libfido2
    /// opens it with `kIOHIDOptionsTypeSeizeDevice`, which locks every other process out for
    /// the duration. So this is never called because a key appeared: a key plugged in to be
    /// reset with an external tool has to stay free. Only a request from the user gets here.
    func refreshStatus(for device: FidoDevice) async {
        let path = device.path
        let token = lease(for: path)
        guard let status = try? await worker.device(validity: token, { try $0.status(devicePath: path) }),
              token.isValid, KeyOperationContext.lease?.isValid != false,
              var state = states[path] else { return }
        state.pinRetriesRemaining = status.pinRetriesRemaining
        state.hasPIN = status.hasPIN
        state.minPINLength = status.minPINLength
        state.forcePINChange = status.forcePINChange
        state.aaguid = status.aaguid
        state.supportsLargeBlobs = status.supportsLargeBlobs
        states[path] = state
    }
}
