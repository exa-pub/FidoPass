import Foundation
import FidoPassCore

extension AccountsViewModel {
    func reload() {
        if reloading { return }
        reloading = true
        defer { reloading = false }
        do {
            let list = try core.listDevices()
            applyDeviceList(list)
            accounts = try loadAccountsForUnlockedDevices().sorted { $0.id < $1.id }
            if let current = selected,
               !accounts.contains(where: { $0.id == current.id && $0.devicePath == current.devicePath }) {
                selected = nil
            }
            autoSelectFirstAccountIfPossible(for: selectedDevicePath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockDevice(_ device: FidoDevice, pin: String) {
        guard !pin.isEmpty else { return }
        Task {
            do {
                _ = try core.enumerateAccounts(devicePath: device.path, pin: pin)
                await MainActor.run {
                    var state = deviceStates[device.path] ?? DeviceState(device: device)
                    state.pin = pin
                    state.unlocked = true
                    deviceStates[device.path] = state
                    showToast("Device unlocked", icon: "lock.open", style: .success)
                }
                await MainActor.run { self.reload() }
            } catch {
                await MainActor.run {
                    self.errorMessage = "PIN is incorrect: \(error.localizedDescription)"
                }
            }
        }
    }

    func lockDevice(_ device: FidoDevice) {
        if var state = deviceStates[device.path] {
            state.unlocked = false
            state.pin = ""
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

    private func applyDeviceList(_ list: [FidoDevice]) {
        devices = list
        var updatedStates: [String: DeviceState] = [:]
        for device in list {
            let previous = deviceStates[device.path]
            let state = DeviceState(device: device,
                                    unlocked: previous?.unlocked ?? false,
                                    pin: previous?.pin ?? "")
            updatedStates[device.path] = state
        }
        deviceStates = updatedStates

        guard !list.isEmpty else {
            selectedDevicePath = nil
            return
        }

        if let current = selectedDevicePath, updatedStates[current] != nil {
            return
        }
        selectedDevicePath = list.first?.path
    }

    private func loadAccountsForUnlockedDevices() throws -> [Account] {
        var collected: [Account] = []
        for (path, state) in deviceStates where state.unlocked {
            let pin = state.pin
            collected.append(contentsOf: enumerateAccounts(devicePath: path, pin: pin))
            collected.append(contentsOf: enumerateAccounts(devicePath: path, pin: pin, rpId: "fidopass.portable"))
        }
        return collected
    }

    private func enumerateAccounts(devicePath: String,
                                   pin: String?,
                                   rpId: String = "fidopass.local") -> [Account] {
        do {
            return try core.enumerateAccounts(rpId: rpId,
                                              devicePath: devicePath,
                                              pin: pin)
        } catch {
            return []
        }
    }

    private func autoSelectFirstAccountIfPossible(for path: String?) {
        guard selected == nil,
              let path,
              deviceStates[path]?.unlocked == true else { return }
        if let first = accounts.first(where: { $0.devicePath == path }) {
            selected = first
        }
    }
}
