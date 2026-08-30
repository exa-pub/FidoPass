@preconcurrency import FidoPassCore
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
        /// PIN attempts the authenticator says are left, or `nil` when it declines to say.
        ///
        /// Never render `nil` as reassurance: eight consecutive failures lock the key for
        /// good, and for a vault master password there is no way back from that.
        var pinRetriesRemaining: Int?
    }

    @Published private(set) var devices: [FidoDevice] = []
    @Published private(set) var states: [String: KeyState] = [:]
    @Published private(set) var isRefreshing = false
    /// Set when the last enumeration failed. Distinct from "no devices": the difference is
    /// the whole point.
    @Published private(set) var refreshError: String?
    /// Which key the HUD is pointed at. Only meaningful with more than one connected.
    @Published var selectedPath: String?

    /// Fired when a key stops being usable — locked, PIN expired, unplugged. The argument
    /// is the device path whose accounts and results must now be dropped.
    var onKeyClosed: ((String) -> Void)?
    /// Fired when the machine's session locks; everything derived must go with it.
    var onSessionLocked: (() -> Void)?
    var onDeviceListChanged: (() -> Void)?

    private var pendingRefresh = false
    private let worker: KeyWorker
    private let pinVault: SecurePinVault
    /// How long the PIN stays in the vault without being used. Settable: the user can change
    /// it in Preferences while a key is already unlocked.
    private(set) var pinTTL: TimeInterval
    /// How long to wait before believing that a key which was here a moment ago is gone.
    private let emptyConfirmationDelay: Duration
#if os(macOS)
    private var deviceMonitor: DeviceMonitorService?
    private var sessionMonitor: SessionLockMonitor?
#endif

    init(backend: KeyBackend,
         pinVault: SecurePinVault = SecurePinVault(defaultTTL: 300),
         pinTTL: TimeInterval = 300,
         emptyConfirmationDelay: Duration = .milliseconds(700),
         enableMonitors: Bool = true) {
        self.worker = KeyWorker(backend: backend)
        self.pinVault = pinVault
        self.pinTTL = pinTTL
        self.emptyConfirmationDelay = emptyConfirmationDelay
#if os(macOS)
        guard enableMonitors else { return }
        deviceMonitor = DeviceMonitorService { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        sessionMonitor = SessionLockMonitor { [weak self] in
            Task { @MainActor in self?.handleSessionLock() }
        }
#endif
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
            listed = try await worker.run { try $0.listDevices() }
        } catch {
            // "Could not ask" is not "nothing is there". Clearing here would release the PIN
            // token and drop every account of a key that never went anywhere — which is
            // exactly what a transient enumeration failure after a touch used to do.
            refreshError = FidoPassErrorPresenter.message(for: error).title
            return
        }

        // A key that has just been touched drops off the HID registry for a moment while it
        // re-enumerates, and one empty read in that window is noise, not an unplug. Confirm
        // before believing it.
        if listed.isEmpty, !devices.isEmpty {
            try? await Task.sleep(for: emptyConfirmationDelay)
            let confirmation: [FidoDevice]
            do {
                confirmation = try await worker.run { try $0.listDevices() }
            } catch {
                refreshError = FidoPassErrorPresenter.message(for: error).title
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
                                            pinRetriesRemaining: old?.pinRetriesRemaining)
        }

        // A key that vanished takes its state with it, which would strand its vault token
        // while the PIN itself stayed in memory until the TTL expired. Release it here.
        let vanished = Set(previous.keys).subtracting(updated.keys)
        for path in vanished {
            if let token = previous[path]?.pinToken { pinVault.remove(token: token) }
        }

        devices = sorted
        states = updated

        for path in vanished { onKeyClosed?(path) }

        if let current = selectedPath, updated[current] == nil { selectedPath = nil }
        if selectedPath == nil { selectedPath = sorted.first?.path }
        if !vanished.isEmpty || previous.keys.count != updated.keys.count { onDeviceListChanged?() }
    }

    // MARK: - Unlock / lock

    /// Verifies the PIN by asking the key to enumerate, then keeps it in the vault.
    ///
    /// Enumerating is the cheapest operation that actually exercises the PIN: it needs no
    /// touch, so a wrong PIN costs the user nothing but the attempt itself.
    func unlock(_ device: FidoDevice, pin: String) async throws {
        guard !pin.isEmpty else { return }
        let path = device.path
        do {
            _ = try await worker.run { try $0.enumerateAccounts(kind: .local, devicePath: path, pin: pin) }
        } catch {
            await recordUnlockFailure(error, for: device)
            throw error
        }

        var state = states[path] ?? KeyState(device: device)
        if let existing = state.pinToken { pinVault.remove(token: existing) }
        state.pinToken = pinVault.store(pin: pin, ttl: pinTTL) { [weak self] in
            Task { @MainActor in self?.handlePinExpiration(for: path) }
        }
        state.unlocked = true
        state.pinRetriesRemaining = nil
        states[path] = state
    }

    private func recordUnlockFailure(_ error: Error, for device: FidoDevice) async {
        let presented = FidoPassErrorPresenter.message(for: error)
        var state = states[device.path] ?? KeyState(device: device)
        switch presented.kind {
        case .pinInvalid:
            let path = device.path
            state.pinRetriesRemaining = (try? await worker.run { try $0.status(devicePath: path).pinRetriesRemaining }) ?? nil
        case .pinBlocked, .pinAuthBlocked:
            state.pinRetriesRemaining = 0
        default:
            break
        }
        states[device.path] = state
    }

    func lock(path: String) {
        guard var state = states[path] else { return }
        if let token = state.pinToken { pinVault.remove(token: token) }
        state.unlocked = false
        state.pinToken = nil
        states[path] = state
        onKeyClosed?(path)
    }

    func lockAll() {
        for path in unlockedPaths { lock(path: path) }
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
    func pinProvider(for path: String) -> (() -> String?)? {
        guard let token = states[path]?.pinToken else { return nil }
        let vault = pinVault
        let ttl = pinTTL
        return { vault.pin(for: token, extending: ttl) }
    }

    /// Reads how many PIN attempts are left before the key locks itself for good.
    ///
    /// Costs no PIN and no touch, so it is safe to call whenever the unlock prompt appears —
    /// which is the only moment the number can still change the user's behaviour.
    func refreshRetries(for device: FidoDevice) async {
        let path = device.path
        let remaining = (try? await worker.run { try $0.status(devicePath: path).pinRetriesRemaining }) ?? nil
        guard let remaining, var state = states[path] else { return }
        state.pinRetriesRemaining = remaining
        states[path] = state
    }

    func status(for device: FidoDevice) async -> DeviceStatus? {
        let path = device.path
        return try? await worker.run { try $0.status(devicePath: path) }
    }
}
