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
                var collected: [Account] = []
                collected.reserveCapacity(pinMap.count * 2)
                for (path, pin) in pinMap {
                    collected.append(contentsOf: try core.enumerateAccounts(devicePath: path, pin: pin))
                    collected.append(contentsOf: try core.enumerateAccounts(rpId: "fidopass.portable",
                                                                            devicePath: path,
                                                                            pin: pin))
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyDeviceList(devices)
                    self.accounts = collected.sorted { $0.id < $1.id }
                    if let current = self.selected,
                       !self.accounts.contains(where: { $0.id == current.id && $0.devicePath == current.devicePath }) {
                        self.selected = nil
                    }
                    self.autoSelectFirstAccountIfPossible(for: self.selectedDevicePath)
                    self.reloading = false
                    self.flushPendingReloadIfNeeded()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.errorMessage = error.localizedDescription
                    self.reloading = false
                    self.flushPendingReloadIfNeeded()
                }
            }
        }
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
                    deviceStates[device.path] = state
                    showToast("Device unlocked", icon: "lock.open", style: .success)
                }
                await MainActor.run { self.reload(trigger: .manual) }
            } catch {
                await MainActor.run {
                    self.errorMessage = "PIN is incorrect: \(error.localizedDescription)"
                }
            }
        }
    }

    func lockDevice(_ device: FidoDevice) {
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

    func lockAllDevices(reason: String? = nil) {
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
                                    pinDraft: previous?.pinDraft ?? "")
            updatedStates[device.path] = state
        }
        deviceStates = updatedStates

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
