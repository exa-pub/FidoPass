import FidoPassCore
import Foundation

/// Manager selection, inventory and key settings. Reads require an explicit open,
/// selection or refresh; passive hot-plug must not seize a key.
@MainActor
final class ManagerStore: ObservableObject {

    enum Sheet: String, Identifiable {
        case changePIN, reset
        var id: String { rawValue }
    }

    @Published var chosenPath: String? {
        didSet { if chosenPath != oldValue { clearForms() } }
    }
    private var lifetime = OperationLease()
    private var requestedPath: String?
    private var receivedAppearance = false
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

    func managerDidOpen() async {
        if chosenPath == nil || device == nil { chosenPath = devices.devices.first?.path }
        requestedPath = device?.path
        receivedAppearance = true
        await deviceDidAppear()
    }

    func managerDidClose() {
        clearForms()
        reset.cancel()
        inventory.dropAll()
    }

    func selectDevice(path: String) async {
        chosenPath = path
        requestedPath = path
        receivedAppearance = true
        await deviceDidAppear()
    }

    func keyDidClose(_ path: String) {
        if chosenPath == path || pinForm.boundPath == path { clearForms() }
    }

    private func clearForms() {
        lifetime.invalidate()
        lifetime = OperationLease()
        pinForm.clear()
        pinError = nil
        settingsError = nil
        selectedCredential = nil
        if sheet == .changePIN { sheet = nil }
    }

    // MARK: - The key on screen

    /// The key the window shows: the chosen one, or the first while there is only one.
    var device: FidoDevice? {
        if let chosenPath { return devices.devices.first(where: { $0.path == chosenPath }) }
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

    /// Services the requested appearance once. Skip reads while reset owns the key.
    func deviceDidAppear() async {
        if !receivedAppearance {
            receivedAppearance = true
            requestedPath = device?.path
        }
        guard let device, !inventory.reading(for: device.path).hasAnything else { return }
        guard requestedPath == device.path else { return }
        guard !isResetting else { return }
        try? await touchGate.withBusy("Reading key…", surface: .manager) {
            await inventory.read(device)
            if let info = inventory.reading(for: device.path).info { devices.adoptInfo(info, for: device.path) }
        }
    }

    /// ⌘R — a deliberate re-read.
    func read() async {
        guard let device else { return }
        try? await touchGate.withBusy("Reading key…", surface: .manager) {
            await inventory.read(device)
            if let info = inventory.reading(for: device.path).info { devices.adoptInfo(info, for: device.path) }
        }
    }

    /// Unlocking completes a read that stopped for want of a PIN. A key nobody asked about is
    /// left alone — `InventoryStore.resumeAfterUnlock` checks.
    func keyDidUnlock() async {
        guard let device else { return }
        try? await touchGate.withBusy("Reading credentials…", surface: .manager) { await inventory.resumeAfterUnlock(device) }
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

    /// Applies a setting and reads back the result; alwaysUv toggles rather than sets a value.
    private func apply(_ operation: (FidoDevice) async throws -> Void) async {
        guard let device, !isApplying, !touchGate.isWorking else { return }
        let token = lifetime
        settingsError = nil
        isApplying = true
        defer { isApplying = false }
        do {
            try await touchGate.withBusy("Applying setting…", surface: .manager) {
                try await operation(device)
                try KeyOperationContext.check(token)
                await devices.refreshStatus(for: device)
                await inventory.refreshInfo(device)
            }
        } catch {
            guard token.isValid, !(error is CancellationError) else { return }
            settingsError = PresentedError(error)
        }
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
        let token = lifetime
        pinError = nil
        do {
            guard try await pinForm.submit() else { return }
            try KeyOperationContext.check(token)
            sheet = nil
        } catch {
            guard token.isValid, !(error is CancellationError) else { return }
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
