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
    @Published var devices: [FidoDevice] = []
    @Published var deviceStates: [String: DeviceState] = [:]
    @Published var selectedDevicePath: String? = nil
    @Published var labelInput: String = "default"
    @Published var recentLabels: [String] = []
    @Published var generatingAccountId: String? = nil
    @Published var showDeleteConfirm: Bool = false
    @Published var accountPendingDeletion: Account? = nil
    @Published var accountSearch: String = ""
    @Published var showPlainPassword: Bool = false
    @Published var lastCopiedPasswordAt: Date? = nil
    @Published var focusSearchFieldToken: Int = 0
    @Published var reloading: Bool = false
    @Published var toastMessage: ToastMessage? = nil
    @Published var enrollmentPhase: EnrollmentPhase = .idle

    enum EnrollmentPhase: Equatable {
        case idle
        case waiting(message: String)
        case success(message: String)
        case failure(message: String)

        static func == (lhs: EnrollmentPhase, rhs: EnrollmentPhase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case let (.waiting(left), .waiting(right)):
                return left == right
            case let (.success(left), .success(right)):
                return left == right
            case let (.failure(left), .failure(right)):
                return left == right
            default:
                return false
            }
        }
    }

    struct DeviceState: Identifiable, Hashable {
        let device: FidoDevice
        var unlocked: Bool = false
        var pinToken: SecurePinVault.Token? = nil
        var pinDraft: String = ""
        var id: String { device.path }
    }

    struct ToastMessage: Identifiable, Equatable {
        enum Style { case info, success, warning, error }

        let id = UUID()
        let icon: String?
        let title: String
        let subtitle: String?
        let style: Style
    }

    let core: FidoPassCore
    let userDefaultsKey = "recentLabels"
    let ubiquitousKey = "recentLabels"
    let ubiStore = NSUbiquitousKeyValueStore.default
    let pinVault = SecurePinVault(defaultTTL: 300)
    let pinTTL: TimeInterval = 300
    private var ubiObserver: NSObjectProtocol?
    var toastTask: Task<Void, Never>? = nil

    init(core: FidoPassCore = .shared) {
        self.core = core
        loadRecentLabels()
        ubiObserver = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                             object: ubiStore,
                                                             queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.mergeUbiquitous() }
        }
    }

    deinit {
        if let observer = ubiObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        toastTask?.cancel()
        pinVault.removeAll()
    }

    func resetEnrollmentState() {
        enrollmentPhase = .idle
    }

    func currentPin(forDevicePath path: String?, extendTTL: Bool = true) -> String? {
        guard let resolved = path else { return nil }
        return currentPin(for: resolved, extendTTL: extendTTL)
    }

    func currentPin(for path: String, extendTTL: Bool = true) -> String? {
        guard let token = deviceStates[path]?.pinToken else { return nil }
        let ttl = extendTTL ? pinTTL : nil
        if let pin = pinVault.pin(for: token, extending: ttl) {
            return pin
        }
        handlePinExpiration(for: path, notify: true)
        return nil
    }

    func makePinProvider(for devicePath: String?) -> (() -> String?)? {
        guard let path = devicePath,
              let token = deviceStates[path]?.pinToken else { return nil }
        let vault = pinVault
        let ttl = pinTTL
        return {
            vault.pin(for: token, extending: ttl)
        }
    }

    func handlePinExpiration(for path: String, notify: Bool) {
        guard var state = deviceStates[path], state.unlocked else { return }
        state.unlocked = false
        state.pinToken = nil
        state.pinDraft = ""
        deviceStates[path] = state
        accounts.removeAll { $0.devicePath == path }
        if let current = selected, current.devicePath == path {
            selected = nil
        }
        if notify {
            showToast("Device locked", icon: "lock.fill", style: .warning, subtitle: "PIN expired; unlock again")
        }
    }
}

extension AccountsViewModel.ToastMessage.Style {
    var tintColor: Color {
        switch self {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
