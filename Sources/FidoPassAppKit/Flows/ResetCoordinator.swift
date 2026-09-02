import FidoPassCore
import Foundation

/// Erasing a key, from the first warning to the touch that does it.
///
/// One owner for a flow that used to be split between the panel's store (the stages, the
/// confirmation) and `DeviceStore` (the arming, the hot-plug callback). The key dictates the
/// shape: most authenticators accept a reset only within seconds of power-up, so the user
/// unplugs it, plugs it back in, and the reset fires the moment it reappears — and then the
/// key asks to be touched.
@MainActor
final class ResetCoordinator: ObservableObject {

    enum Refusal: LocalizedError {
        /// After the reconnect the path is different and a vendor signature only names a
        /// model — there is no way left to prove which key came back, and an operation that
        /// erases everything may not proceed on a guess.
        case multipleKeys

        var errorDescription: String? {
            switch self {
            case .multipleKeys:
                return "Resetting works with one key connected. Unplug the others first — after the key is reconnected there is no way to tell two apart, and this erases everything on whichever one is there."
            }
        }
    }

    /// The wizard, or nil when none is running.
    @Published var flow: ResetFlow?
    /// What went wrong at the last step, for the wizard to show.
    @Published private(set) var error: PresentedError?
    /// The reset triggered by the key reappearing, while it runs. Held so the work is
    /// reachable: it starts from a hot-plug callback, and without a handle nothing — a test,
    /// or a later step of the wizard — can tell whether it has finished.
    private(set) var task: Task<Void, Never>?
    /// The key was erased. Whoever shows the account list wants to know.
    var onCompleted: (() -> Void)?

    private let devices: DeviceStore
    private let accounts: AccountStore
    private let labels: LabelStore
    private let preferences: Preferences
    private let touchGate: TouchGate

    init(devices: DeviceStore,
         accounts: AccountStore,
         labels: LabelStore,
         preferences: Preferences,
         touchGate: TouchGate) {
        self.devices = devices
        self.accounts = accounts
        self.labels = labels
        self.preferences = preferences
        self.touchGate = touchGate
    }

    /// True from the moment the wizard opens until the key is erased or the flow cancelled.
    var isResetting: Bool { flow != nil || devices.armedReset != nil }

    /// Opens the wizard for `device`. Throws `Refusal` when it cannot start.
    func begin(device: FidoDevice) async throws {
        guard !touchGate.isWorking else { return }
        guard devices.devices.count == 1 else { throw Refusal.multipleKeys }
        // A user request, so opening the key here is allowed — and the AAGUID it returns is
        // the only thing that will notice a different key coming back.
        await devices.refreshStatus(for: device)

        let state = devices.state(for: device.path)
        let onKey = accounts.accounts(onDevice: device.path)
        let readable = state?.unlocked == true && state?.hasPIN != false
        error = nil
        flow = ResetFlow(deviceName: device.displayName,
                         expectedAAGUID: state?.aaguid,
                         doomed: onKey.compactMap { account in
                             AccountRef(account).map { ResetFlow.Doomed(ref: $0, kind: account.kind) }
                         },
                         accountsReadable: readable,
                         scopes: onKey.map { LabelScope(credentialId: $0.credentialIdB64) })
    }

    /// Confirmed. From here on the key is what drives the flow.
    func arm() {
        guard var flow, flow.stage == .confirm, flow.canProceed else { return }
        flow.stage = .unplug
        self.flow = flow
        devices.armReset(expectedAAGUID: flow.expectedAAGUID)
        error = nil
    }

    func cancel() {
        devices.disarmReset()
        flow = nil
        error = nil
    }

    /// The wizard is waiting for exactly this: the key has gone, so the next thing to happen
    /// is it coming back.
    func keyDidClose(_ path: String) {
        if flow?.stage == .unplug, devices.armedReset != nil {
            flow?.stage = .replug
        }
    }

    /// The key came back while a reset was armed. This runs on the millisecond, not after the
    /// usual refresh: the window in which most keys accept a reset is a few seconds wide.
    func armedKeyAppeared(_ device: FidoDevice) {
        task = Task { @MainActor [weak self] in await self?.performArmedReset(on: device) }
    }

    private func performArmedReset(on device: FidoDevice) async {
        guard var flow, flow.stage == .unplug || flow.stage == .replug else { return }
        devices.disarmReset()
        flow.stage = .running
        self.flow = flow
        let scopes = flow.scopes

        do {
            // The wizard is a sheet in the manager window, so that is where the prompt goes.
            try await touchGate.withTouchPrompt(TouchPrompt(title: "Touch the key to confirm the reset",
                                                            message: "This erases everything on it. The key gives you about 30 seconds.",
                                                            deviceName: device.displayName),
                                                surface: .manager) {
                try await devices.resetKey(device, expectedAAGUID: flow.expectedAAGUID)
            }
            // The credential ids these histories are keyed by will never exist again, so the
            // histories would be orphaned for good. Everything else on the key was already
            // dropped by `adoptResetKey` closing it.
            for scope in scopes { labels.forget(scope) }
            preferences.forgetLastUsed()
            self.flow = nil
            onCompleted?()
        } catch {
            self.flow?.stage = .replug
            // `FIDO_ERR_NOT_ALLOWED` here means the window closed: the command arrived too
            // late, not that anything was refused on its merits.
            self.error = PresentedError(error, meaningOfRefusal: "The key had already been awake too long — most keys only accept a reset in the first seconds after being plugged in. Unplug it and plug it back in to try again.")
        }
    }
}
