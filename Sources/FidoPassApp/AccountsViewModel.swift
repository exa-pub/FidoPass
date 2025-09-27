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
    @Published var accountSearch: String = "" // live search filter
    @Published var showPlainPassword: Bool = false // reveal generated password
    @Published var lastCopiedPasswordAt: Date? = nil // ephemeral toast timestamp
    @Published var focusSearchFieldToken: Int = 0
    @Published var reloading: Bool = false
    @Published var toastMessage: ToastMessage? = nil
    @Published var enrollmentPhase: EnrollmentPhase = .idle

    enum EnrollmentPhase: Equatable {
        case idle
        case waiting(message: String)
        case success(message: String)
        case failure(message: String)

        static func ==(lhs: EnrollmentPhase, rhs: EnrollmentPhase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case let (.waiting(l), .waiting(r)): return l == r
            case let (.success(l), .success(r)): return l == r
            case let (.failure(l), .failure(r)): return l == r
            default: return false
            }
        }
    }

    struct DeviceState: Identifiable, Hashable {
        let device: FidoPassCore.FidoDevice
        var unlocked: Bool = false
        var pin: String = ""
        var id: String { device.path }
    }
    @Published var deviceStates: [String: DeviceState] = [:]

    struct ToastMessage: Identifiable, Equatable {
        enum Style { case info, success, warning, error }

        let id = UUID()
        let icon: String?
        let title: String
        let subtitle: String?
        let style: Style
    }

    private let core = FidoPassCore.shared
    private let userDefaultsKey = "recentLabels"
    private let ubiquitousKey = "recentLabels"
    private let ubiStore = NSUbiquitousKeyValueStore.default
    private var ubiObserver: NSObjectProtocol?
    private var toastTask: Task<Void, Never>? = nil

    init() {
        loadRecentLabels()
        // Observe iCloud key-value sync updates
        ubiObserver = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: ubiStore, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.mergeUbiquitous() }
        }
    }

    deinit {
        if let o = ubiObserver { NotificationCenter.default.removeObserver(o) }
        toastTask?.cancel()
    }

    func reload() {
        if reloading { return }
        reloading = true
        defer { reloading = false }
        do {
            let list = try core.listDevices()
            applyDeviceList(list)
            accounts = try loadAccountsForUnlockedDevices().sorted { $0.id < $1.id }
            if let current = selected, !accounts.contains(where: { $0.id == current.id && $0.devicePath == current.devicePath }) {
                selected = nil
            }
            autoSelectFirstAccountIfPossible(for: selectedDevicePath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDeviceList(_ list: [FidoPassCore.FidoDevice]) {
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

    private func enumerateAccounts(devicePath: String, pin: String?, rpId: String = "fidopass.local") -> [Account] {
        do {
            return try core.enumerateAccounts(rpId: rpId, devicePath: devicePath, pin: pin)
        } catch {
            return []
        }
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
                    self.showToast("Device unlocked", icon: "lock.open", style: .success)
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
        enrollmentPhase = .waiting(message: "Touch your security key to confirm")
        let core = self.core
        let account = accountId
        weak var weakSelf = self
        Task.detached(priority: .userInitiated) {
            do {
                let acc = try core.enroll(accountId: account, rpId: rpId, userName: "", requireUV: requireUV, residentKey: true, devicePath: path, askPIN: { pin })
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.accounts.append(acc)
                    self.accounts.sort { $0.id < $1.id }
                    self.showToast("Account added", icon: "plus", style: .success)
                    self.enrollmentPhase = .idle
                    self.showNewAccountSheet = false
                }
            } catch {
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.errorMessage = error.localizedDescription
                    self.enrollmentPhase = .failure(message: error.localizedDescription)
                }
            }
        }
    }

    func enrollPortable(accountId: String, importedKeyB64: String?) {
        guard let path = selectedDevicePath, let st = deviceStates[path], st.unlocked else { errorMessage = "Unlock the device first"; return }
        let pin = st.pin
        enrollmentPhase = .waiting(message: "Touch your security key to confirm portable enrollment")
        let core = self.core
        let account = accountId
        weak var weakSelf = self
        Task.detached(priority: .userInitiated) {
            do {
                let (acc, generated) = try core.enrollPortable(accountId: account, requireUV: true, devicePath: path, askPIN: { pin }, importedKeyB64: importedKeyB64)
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.accounts.append(acc)
                    self.accounts.sort { $0.id < $1.id }
                    if let g = generated { self.generatedPassword = "IMPORTED:" + g }
                    self.showToast("Portable account ready", icon: "key.horizontal", style: .success)
                    self.enrollmentPhase = .idle
                    self.showNewAccountSheet = false
                }
            } catch {
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    self.errorMessage = error.localizedDescription
                    self.enrollmentPhase = .failure(message: error.localizedDescription)
                }
            }
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
                    self.showToast("Password generated", icon: "wand.and.stars", style: .success)
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

    func markPasswordCopied() {
        lastCopiedPasswordAt = Date()
        showToast("Password copied", icon: "doc.on.doc.fill", style: .success)
    }

    func deleteAccount(_ account: Account) {
        guard let path = account.devicePath, let st = deviceStates[path], st.unlocked else { return }
        let pin = st.pin
        Task {
            do {
                try core.deleteAccount(account, pin: pin)
                await MainActor.run {
                    accounts.removeAll { $0.id == account.id && $0.devicePath == path }
                    if selected?.id == account.id { selected = nil }
                    self.showToast("Account deleted", icon: "trash", style: .warning)
                }
                // Reload to ensure device view stays in sync (credential removed on token)
                await MainActor.run { self.reload() }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func resetEnrollmentState() {
        enrollmentPhase = .idle
    }

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

    func requestSearchFocus() {
        focusSearchFieldToken &+= 1
    }

    func requestDeleteSelectedAccount() {
        guard let current = selected else { return }
        accountPendingDeletion = current
        showDeleteConfirm = true
    }

    func selectDefaultAccount(for path: String?) {
        autoSelectFirstAccountIfPossible(for: path)
    }

    private func autoSelectFirstAccountIfPossible(for path: String?) {
        guard selected == nil, let path, deviceStates[path]?.unlocked == true else { return }
        if let first = accounts.first(where: { $0.devicePath == path }) {
            selected = first
        }
    }

    func showToast(_ title: String,
                   icon: String? = nil,
                   style: ToastMessage.Style = .info,
                   subtitle: String? = nil,
                   duration: TimeInterval = 3.0) {
        toastTask?.cancel()
        let toast = ToastMessage(icon: icon, title: title, subtitle: subtitle, style: style)
        toastMessage = toast
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                if self?.toastMessage?.id == toast.id {
                    self?.toastMessage = nil
                }
            }
        }
    }
}
