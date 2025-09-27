import Foundation
import SwiftUI
import FidoPassCore

@MainActor
final class AccountsViewModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var selected: Account? = nil {
        didSet {
            if oldValue?.id != selected?.id {
                generatedPassword = nil
                generatingAccountId = nil
                showPlainPassword = false
            }
        }
    }
    @Published var errorMessage: String? = nil
    @Published var showNewAccountSheet = false
    @Published var generatedPassword: String? = nil
    @Published var generating = false
    @Published var devices: [FidoPassCore.FidoDevice] = []
    @Published var selectedDevicePath: String? = nil
    @Published var labelInput: String = "default"
    @Published var recentLabels: [String] = [] // MRU labels (latest first)
    @Published var generatingAccountId: String? = nil
    @Published var showDeleteConfirm: Bool = false
    @Published var accountPendingDeletion: Account? = nil
    // Undo toast removed per request
    @Published var lastDeletedAccount: Account? = nil
    @Published var showUndoBanner: Bool = false // retained but no longer shown
    @Published var accountSearch: String = "" // live search filter
    @Published var showPlainPassword: Bool = false // reveal generated password
    @Published var lastCopiedPasswordAt: Date? = nil // ephemeral toast timestamp

    struct DeviceState: Identifiable, Hashable {
        let device: FidoPassCore.FidoDevice
        var unlocked: Bool = false
        var pin: String = ""
        var id: String { device.path }
    }
    @Published var deviceStates: [String: DeviceState] = [:]

    private let core = FidoPassCore.shared
    private let userDefaultsKey = "recentLabels"
    private let ubiquitousKey = "recentLabels"
    private let ubiStore = NSUbiquitousKeyValueStore.default
    private var ubiObserver: NSObjectProtocol?

    init() {
        loadRecentLabels()
        // Observe iCloud key-value sync updates
        ubiObserver = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: ubiStore, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.mergeUbiquitous() }
        }
    }

    deinit { if let o = ubiObserver { NotificationCenter.default.removeObserver(o) } }

    func reload() {
        do {
            let list = try core.listDevices()
            self.devices = list
            var next: [String: DeviceState] = [:]
            for d in list {
                let previous = deviceStates[d.path]
                let state = DeviceState(device: d, unlocked: previous?.unlocked ?? false, pin: previous?.pin ?? "")
                next[d.path] = state
            }
            deviceStates = next
            if list.isEmpty {
                selectedDevicePath = nil
            } else if let current = selectedDevicePath, !next.keys.contains(current) {
                selectedDevicePath = list.first?.path
            } else if selectedDevicePath == nil {
                selectedDevicePath = list.first?.path
            }
            // refresh accounts only for unlocked devices
            var acc: [Account] = []
            for (path, state) in deviceStates where state.unlocked {
                do {
                    let normal = try core.enumerateAccounts(devicePath: path, pin: state.pin)
                    acc.append(contentsOf: normal)
                } catch { /* ignore normal */ }
                do {
                    let portable = try core.enumerateAccounts(rpId: "fidopass.portable", devicePath: path, pin: state.pin)
                    acc.append(contentsOf: portable)
                } catch { /* ignore portable */ }
            }
            self.accounts = acc.sorted { $0.id < $1.id }
            if let sel = selected, !accounts.contains(where: { $0.id == sel.id }) { selected = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    func unlockDevice(_ device: FidoPassCore.FidoDevice, pin: String) {
        guard !pin.isEmpty else { return }
        Task {
            do {
                _ = try core.enumerateAccounts(devicePath: device.path, pin: pin)
                await MainActor.run {
                    var state = self.deviceStates[device.path] ?? DeviceState(device: device)
                    state.pin = pin
                    state.unlocked = true
                    self.deviceStates[device.path] = state
                }
                await MainActor.run { self.reload() }
            } catch {
                await MainActor.run { self.errorMessage = "PIN is incorrect: \(error.localizedDescription)" }
            }
        }
    }

    func lockDevice(_ device: FidoPassCore.FidoDevice) {
        if var st = deviceStates[device.path] { st.unlocked = false; st.pin = ""; deviceStates[device.path] = st }
        accounts.removeAll { $0.devicePath == device.path }
        if let sel = selected, sel.devicePath == device.path { selected = nil }
    }

    func enroll(accountId: String, rpId: String = "fidopass.local", requireUV: Bool = true) {
        guard let path = selectedDevicePath, let st = deviceStates[path], st.unlocked else { errorMessage = "Unlock the device first"; return }
        let pin = st.pin
        Task {
            do {
                let acc = try core.enroll(accountId: accountId, rpId: rpId, userName: "", requireUV: requireUV, residentKey: true, devicePath: path, askPIN: { pin })
                await MainActor.run {
                    self.accounts.append(acc)
                    self.accounts.sort { $0.id < $1.id }
                    self.showNewAccountSheet = false
                }
            } catch { await MainActor.run { self.errorMessage = error.localizedDescription } }
        }
    }

    func enrollPortable(accountId: String, importedKeyB64: String?) {
        guard let path = selectedDevicePath, let st = deviceStates[path], st.unlocked else { errorMessage = "Unlock the device first"; return }
        let pin = st.pin
        Task {
            do {
                let (acc, generated) = try core.enrollPortable(accountId: accountId, requireUV: true, devicePath: path, askPIN: { pin }, importedKeyB64: importedKeyB64)
                await MainActor.run {
                    self.accounts.append(acc)
                    self.accounts.sort { $0.id < $1.id }
                    if let g = generated { self.generatedPassword = "IMPORTED:" + g } // temporary place to show generated key
                    self.showNewAccountSheet = false
                }
            } catch { await MainActor.run { self.errorMessage = error.localizedDescription } }
        }
    }

    func generatePassword(for account: Account, label: String) {
        generating = true
        generatingAccountId = account.id
        generatedPassword = nil
        let pin = deviceStates[account.devicePath ?? ""]?.pin
        Task {
            do {
                let pwd = try core.generatePassword(account: account, label: label, requireUV: true, pinProvider: { pin })
                await MainActor.run {
                    self.generatedPassword = pwd
                    if !label.isEmpty { self.addRecentLabel(label) }
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run {
                self.generating = false
                self.generatingAccountId = nil
            }
        }
    }

    func markPasswordCopied() { lastCopiedPasswordAt = Date() }

    func deleteAccount(_ account: Account) {
        guard let path = account.devicePath, let st = deviceStates[path], st.unlocked else { return }
        let pin = st.pin
        Task {
            do {
                try core.deleteAccount(account, pin: pin)
                await MainActor.run {
                    // Removed undo banner behavior
                    lastDeletedAccount = nil
                    showUndoBanner = false
                    accounts.removeAll { $0.id == account.id && $0.devicePath == path }
                    if selected?.id == account.id { selected = nil }
                }
                // Reload to ensure device view stays in sync (credential removed on token)
                await MainActor.run { self.reload() }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func undoLastDeletion() { /* no-op; feature removed */ }

    // MARK: - Recent Labels Persistence
    private func addRecentLabel(_ label: String) {
        recentLabels.removeAll { $0 == label }
        recentLabels.insert(label, at: 0)
        if recentLabels.count > 10 { recentLabels.removeLast(recentLabels.count - 10) }
        saveRecentLabels()
    }

    private func saveRecentLabels() {
        let arr = recentLabels
        UserDefaults.standard.set(arr, forKey: userDefaultsKey)
        ubiStore.set(arr, forKey: ubiquitousKey)
        ubiStore.synchronize()
    }

    private func loadRecentLabels() {
        // Prefer merged view between local defaults and iCloud
        var local = (UserDefaults.standard.array(forKey: userDefaultsKey) as? [String]) ?? []
        if let cloud = ubiStore.array(forKey: ubiquitousKey) as? [String] { // merge maintaining order from cloud priority
            for l in cloud.reversed() where !local.contains(l) { local.insert(l, at: 0) }
        }
        recentLabels = Array(local.prefix(10))
    }

    private func mergeUbiquitous() {
        // Called on iCloud external change
        let before = Set(recentLabels)
        if let cloud = ubiStore.array(forKey: ubiquitousKey) as? [String] {
            var merged = recentLabels
            for l in cloud where !merged.contains(l) { merged.append(l) }
            // keep most recent semantics: items earlier in cloud list go to front if new
            // For simplicity, reorder by first appearance across both preserving existing front order
            recentLabels = Array(merged.prefix(10))
            if Set(recentLabels) != before { UserDefaults.standard.set(recentLabels, forKey: userDefaultsKey) }
        }
    }
}
