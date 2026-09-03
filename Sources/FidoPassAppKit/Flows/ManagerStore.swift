import FidoPassCore
import Foundation

/// The manager window's state: which key it looks at, what it shows, and the operations on
/// the key itself that live here rather than in the panel.
///
/// **Reading the key happens when the window opens, and never otherwise.** Opening a key on
/// macOS seizes it away from every other process, so a window that read on its own — because
/// a key appeared, or because it merely existed — would make `ykman` unusable for as long as
/// it was open. Choosing the window from a menu is the request; `deviceDidAppear` is what
/// that request runs.
@MainActor
final class ManagerStore: ObservableObject {

    enum Sheet: String, Identifiable {
        case changePIN, reset
        var id: String { rawValue }
    }

    @Published var chosenPath: String?
    @Published var tab: ManagerTab = .credentials
    @Published var selectedCredential: String?
    @Published var sheet: Sheet?
    @Published private(set) var isApplying = false
    @Published private(set) var settingsError: PresentedError?
    /// What the change-PIN sheet has to say. Its own, not the panel's.
    @Published private(set) var pinError: PresentedError?

    /// The change-PIN form. The panel has its own for bootstrap; sharing one was a defect.
    let pinForm: PinFormModel
    let reset: ResetCoordinator

    private let devices: DeviceStore
    private let inventory: InventoryStore
    private let touchGate: TouchGate
    private let router: WindowRouter

    init(devices: DeviceStore,
         inventory: InventoryStore,
         touchGate: TouchGate,
         reset: ResetCoordinator,
         router: WindowRouter) {
        self.devices = devices
        self.inventory = inventory
        self.touchGate = touchGate
        self.reset = reset
        self.router = router
        self.pinForm = PinFormModel(mode: .change,
                                    devices: devices,
                                    touchGate: touchGate,
                                    surface: .manager,
                                    device: { nil })
        pinForm.device = { [weak self] in self?.device }
    }

    // MARK: - The key on screen

    /// The key the window shows: the chosen one, or the first while there is only one.
    var device: FidoDevice? {
        if let chosenPath, let match = devices.devices.first(where: { $0.path == chosenPath }) { return match }
        return devices.devices.first
    }

    var keyState: DeviceStore.KeyState? {
        device.flatMap { devices.state(for: $0.path) }
    }

    var isUnlocked: Bool { keyState?.unlocked == true }

    var reading: InventoryStore.Reading {
        guard let device else { return InventoryStore.Reading() }
        return inventory.reading(for: device.path)
    }

    var isResetting: Bool { reset.isResetting }

    // MARK: - Reading

    /// The window opened, or the user switched to another key. Reads the key unless it has
    /// been read already.
    ///
    /// A reset makes the key reappear on a new path, which is exactly what re-triggers this.
    /// Reading it then would seize the device in the seconds-wide window where the reset has
    /// to be issued — and there is nothing worth reading off a key that is about to be erased.
    func deviceDidAppear() async {
        guard let device, !inventory.reading(for: device.path).hasAnything else { return }
        guard !isResetting else { return }
        await inventory.read(device)
    }

    /// ⌘R — a deliberate re-read.
    func read() async {
        guard let device else { return }
        await inventory.read(device)
    }

    /// Unlocking completes a read that stopped for want of a PIN. A key nobody asked about is
    /// left alone — `InventoryStore.resumeAfterUnlock` checks.
    func keyDidUnlock() async {
        guard let device else { return }
        await inventory.resumeAfterUnlock(device)
    }

    /// Sends the user to the panel's PIN field. The manager has no PIN field of its own — a
    /// second place to type a PIN is a second place to spend one of the eight attempts.
    func requestUnlock() {
        guard let device else { return }
        devices.selectedPath = device.path
        router.openPanel()
    }

    // MARK: - Authenticator settings

    func toggleAlwaysUV() async {
        await apply { device in _ = try await self.devices.toggleAlwaysUV(for: device) }
    }

    func raiseMinimumPIN(to length: Int) async {
        await apply { device in try await self.devices.setMinimumPINLength(for: device, length: length) }
    }

    func forcePINChange() async {
        await apply { device in try await self.devices.forcePINChange(for: device) }
    }

    func enableEnterpriseAttestation() async {
        await apply { device in try await self.devices.enableEnterpriseAttestation(for: device) }
    }

    /// Runs one setting change and then re-reads the key.
    ///
    /// The re-read is not optional: `alwaysUv` is a *toggle*, so the resulting state is
    /// whatever the key now says rather than what the switch was moved to, and a control
    /// showing the app's guess instead of the key's answer is how a setting silently reads
    /// backwards.
    private func apply(_ operation: (FidoDevice) async throws -> Void) async {
        guard let device, !isApplying else { return }
        settingsError = nil
        isApplying = true
        defer { isApplying = false }
        do {
            try await operation(device)
        } catch {
            settingsError = PresentedError(error)
        }
        await inventory.refreshInfo(device)
    }

    // MARK: - PIN

    func beginChangePIN() {
        pinForm.clear()
        pinError = nil
        sheet = .changePIN
    }

    func cancelChangePIN() {
        pinForm.clear()
        pinError = nil
        sheet = nil
    }

    /// Sends the new PIN, and leaves the sheet up on failure: a wrong old PIN costs one of the
    /// eight attempts, and closing would hide the count that says so.
    func changePIN() async {
        pinError = nil
        do {
            guard try await pinForm.submit() else { return }
            sheet = nil
        } catch {
            pinError = PresentedError(error)
        }
    }

    // MARK: - Reset

    func beginReset() async {
        guard let device else { return }
        settingsError = nil
        do {
            try await reset.begin(device: device)
            sheet = .reset
        } catch {
            settingsError = .plain(error.localizedDescription)
        }
    }

    func cancelReset() {
        reset.cancel()
        sheet = nil
    }

    /// The wizard ended — the key was erased, or the flow was cancelled elsewhere.
    func resetSheetFinished() {
        if sheet == .reset { sheet = nil }
    }
}
