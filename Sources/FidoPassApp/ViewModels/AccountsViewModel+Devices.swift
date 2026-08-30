import Foundation
@preconcurrency import FidoPassCore

extension AccountsViewModel {
    func reload(trigger: ReloadTrigger = .manual) {
        if reloading {
            if trigger == .manual {
                pendingReloadTrigger = .manual
            } else if pendingReloadTrigger == nil {
                pendingReloadTrigger = trigger
            }
            return
        }

        reloading = true

        var pinMap: [String: String] = [:]
        for (path, state) in deviceStates where state.unlocked {
            if let pin = currentPin(for: path) {
                pinMap[path] = pin
            }
        }

        let core = self.core
        deviceWorkQueue.async { [weak self] in
            guard let self else { return }
            do {
                let devices = try core.listDevices()
                let outcome = Self.collectAccounts(core: core, pinMap: pinMap)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyDeviceList(devices)
                    self.accounts = outcome.accounts.sorted { $0.id < $1.id }
                    self.deviceErrors = outcome.errors
                    if let current = self.selected, !self.accounts.contains(current) {
                        self.selected = nil
                    }
                    self.autoSelectFirstAccountIfPossible(for: self.selectedDevicePath)
                    self.reloading = false
                    self.reportUnreadableDevices(outcome.errors)
                    self.flushPendingReloadIfNeeded()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.errorMessage = FidoPassErrorPresenter.message(for: error).title
                    self.reloading = false
                    self.flushPendingReloadIfNeeded()
                }
            }
        }
    }

    /// Reads accounts from every unlocked device, keeping failures local to the device
    /// that caused them.
    ///
    /// A single `try` across the loop used to abort the whole refresh: unplugging one key
    /// while another stayed connected produced an alert plus a stale account list. Losing
    /// a device mid-refresh is routine — hot-plug events trigger a reload precisely when
    /// devices appear and disappear.
    private static func collectAccounts(core: FidoPassCore,
                                        pinMap: [String: String]) -> (accounts: [Account], errors: [String: String]) {
        var accounts: [Account] = []
        var errors: [String: String] = [:]

        for (path, pin) in pinMap {
            for kind in AccountKind.allCases {
                do {
                    accounts.append(contentsOf: try core.enumerateAccounts(kind: kind, devicePath: path, pin: pin))
                } catch {
                    // Keep the first failure per device: later kinds usually fail for the
                    // same underlying reason and would just overwrite it.
                    if errors[path] == nil {
                        errors[path] = FidoPassErrorPresenter.message(for: error).title
                    }
                }
            }
        }
        return (accounts, errors)
    }

    private func reportUnreadableDevices(_ errors: [String: String]) {
        guard !errors.isEmpty else { return }
        let names = errors.keys.compactMap { deviceStates[$0]?.device.conciseName }
        let subtitle = names.isEmpty ? nil : names.joined(separator: ", ")
        showToast("Some devices could not be read",
                  icon: "exclamationmark.triangle",
                  style: .warning,
                  subtitle: subtitle)
    }

    func unlockDevice(_ device: FidoDevice, pin: String) {
        guard !pin.isEmpty else { return }
        Task {
            do {
                _ = try core.enumerateAccounts(devicePath: device.path, pin: pin)
                await MainActor.run {
                    var state = deviceStates[device.path] ?? DeviceState(device: device)
                    if let existing = state.pinToken {
                        pinVault.remove(token: existing)
                    }
                    state.pinToken = pinVault.store(pin: pin, ttl: pinTTL) { [weak self] in
                        self?.handlePinExpiration(for: device.path, notify: true)
                    }
                    state.unlocked = true
                    state.pinDraft = ""
                    state.pinRetriesRemaining = nil
                    deviceStates[device.path] = state
                    showToast("Device unlocked", icon: "lock.open", style: .success)
                }
                await MainActor.run { self.reload(trigger: .manual) }
            } catch {
                await MainActor.run { self.handleUnlockFailure(error, for: device) }
            }
        }
    }

    /// Surfaces how many PIN attempts are left, and what a lock-out means.
    ///
    /// A FIDO2 authenticator wipes its credentials only on a factory reset, but it stops
    /// accepting the PIN permanently after eight consecutive failures. For an app whose
    /// whole purpose is deriving keys that have no reset path, running out of attempts is
    /// the single most expensive mistake a user can make, so it must never be a surprise.
    private func handleUnlockFailure(_ error: Error, for device: FidoDevice) {
        let presented = FidoPassErrorPresenter.message(for: error)
        var state = deviceStates[device.path] ?? DeviceState(device: device)

        switch presented.kind {
        case .pinInvalid:
            state.pinRetriesRemaining = (try? core.pinRetriesRemaining(devicePath: device.path)) ?? nil
        case .pinBlocked, .pinAuthBlocked:
            state.pinRetriesRemaining = 0
        default:
            break
        }
        state.pinDraft = ""
        deviceStates[device.path] = state

        errorMessage = presented.fullText(retriesRemaining: state.pinRetriesRemaining)
    }

    func lockDevice(_ device: FidoDevice) {
        // An open editor holds a live encryption key for one of this device's accounts.
        // Locking the device has to take that key with it, or "locked" would only describe
        // the account list while the secrets stayed reachable in another window.
        if cryptoEditor != nil, selected?.devicePath == device.path {
            closeCryptoEditor()
        }
        if var state = deviceStates[device.path] {
            if let token = state.pinToken {
                pinVault.remove(token: token)
            }
            state.unlocked = false
            state.pinToken = nil
            state.pinDraft = ""
            deviceStates[device.path] = state
        }
        accounts.removeAll { $0.devicePath == device.path }
        if let selected, selected.devicePath == device.path {
            self.selected = nil
        }
    }

    func selectDefaultAccount(for path: String?) {
        autoSelectFirstAccountIfPossible(for: path)
    }

    func requestDeleteSelectedAccount() {
        guard let current = selected else { return }
        accountPendingDeletion = current
        showDeleteConfirm = true
    }

    /// Called when the macOS session locks or the screen goes to sleep.
    func lockAllDevices(reason: String? = nil) {
        // Unconditionally, and before anything else: this runs when the user walks away
        // from the machine, and an editing session left open would keep both the key and
        // the plaintext on screen behind the lock screen.
        closeCryptoEditor()

        let unlockedDevices = deviceStates.values.filter { $0.unlocked }.map { $0.device }
        guard !unlockedDevices.isEmpty else { return }

        for device in unlockedDevices {
            lockDevice(device)
        }

        showToast("Devices locked", icon: "lock.fill", style: .warning, subtitle: reason)
    }

    private func applyDeviceList(_ list: [FidoDevice]) {
        let sortedList = list.sorted { lhs, rhs in
            let leftSeed = lhs.identitySeed
            let rightSeed = rhs.identitySeed
            if leftSeed == rightSeed {
                return lhs.path < rhs.path
            }
            return leftSeed < rightSeed
        }

        devices = sortedList
        var updatedStates: [String: DeviceState] = [:]
        for device in sortedList {
            let previous = deviceStates[device.path]
            let state = DeviceState(device: device,
                                    unlocked: previous?.unlocked ?? false,
                                    pinToken: previous?.pinToken,
                                    pinDraft: previous?.pinDraft ?? "",
                                    pinRetriesRemaining: previous?.pinRetriesRemaining)
            updatedStates[device.path] = state
        }

        // Devices that vanished take their state with them, so their vault token would
        // become unreachable while the PIN itself stayed in memory until the TTL expired.
        // Release it here the same way `lockDevice` does.
        for (path, previous) in deviceStates where updatedStates[path] == nil {
            if let token = previous.pinToken {
                pinVault.remove(token: token)
            }
        }
        let vanished = Set(deviceStates.keys).subtracting(updatedStates.keys)
        if !vanished.isEmpty {
            accounts.removeAll { path in vanished.contains(path.devicePath ?? "") }
            if let current = selected, vanished.contains(current.devicePath ?? "") {
                selected = nil
            }
        }

        deviceStates = updatedStates
        deviceErrors = deviceErrors.filter { updatedStates[$0.key] != nil }

        guard !sortedList.isEmpty else {
            selectedDevicePath = nil
            return
        }

        if let current = selectedDevicePath, updatedStates[current] != nil {
            return
        }
        selectedDevicePath = sortedList.first?.path
    }

    private func autoSelectFirstAccountIfPossible(for path: String?) {
        guard selected == nil,
              let path,
              deviceStates[path]?.unlocked == true else { return }
        if let first = accounts.first(where: { $0.devicePath == path }) {
            selected = first
        }
    }

    private func flushPendingReloadIfNeeded() {
        if let next = pendingReloadTrigger {
            pendingReloadTrigger = nil
            reload(trigger: next)
        }
    }
}

extension AccountsViewModel {
    /// Asks the authenticator how many PIN attempts are left, before the user spends one.
    ///
    /// Reading this needs no PIN and no touch, so it is safe to do whenever the unlock
    /// prompt appears. Authenticators that decline to answer leave the value `nil`, which
    /// the UI renders as nothing at all rather than as reassurance.
    func refreshPinRetries(for device: FidoDevice) async {
        let core = self.core
        let path = device.path
        let remaining = await Task.detached(priority: .utility) { () -> Int? in
            try? core.pinRetriesRemaining(devicePath: path)
        }.value

        guard let remaining else { return }
        var state = deviceStates[path] ?? DeviceState(device: device)
        state.pinRetriesRemaining = remaining
        deviceStates[path] = state
    }
}
