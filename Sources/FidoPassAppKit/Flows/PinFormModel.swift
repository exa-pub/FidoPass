import FidoPassCore
import Foundation

/// The fields of a set-PIN or change-PIN form, and the one operation they lead to.
///
/// One instance per screen. The panel's bootstrap screen and the manager's change-PIN sheet
/// used to share a single form on the panel's store, and closing the panel — which happens
/// the moment the manager takes focus — wiped a PIN the user was halfway through typing in
/// the other window.
///
/// Validation is done here rather than by the key. For setting a first PIN that only changes
/// *when* the user finds out, since libfido2 rejects a bad length before it sends anything.
/// For a change it matters far more: a new PIN that was never going to be accepted must not
/// cost one of the eight attempts standing between this key and a permanent lock-out.
@MainActor
final class PinFormModel: ObservableObject {

    enum Mode: Equatable {
        /// The key has never had a PIN. Nothing on it works until it does.
        case bootstrap
        /// Replacing the PIN, having been told the current one.
        case change
    }

    @Published var current = ""
    @Published var new = ""
    @Published var confirm = ""

    let mode: Mode
    private let devices: DeviceStore
    private let touchGate: TouchGate
    private let surface: TouchSurface
    /// The key this form is for. A closure because the owner's idea of "the key" moves:
    /// the panel's selection, the manager's chosen device.
    var device: () -> FidoDevice?

    init(mode: Mode,
         devices: DeviceStore,
         touchGate: TouchGate,
         surface: TouchSurface,
         device: @escaping () -> FidoDevice?) {
        self.mode = mode
        self.devices = devices
        self.touchGate = touchGate
        self.surface = surface
        self.device = device
    }

    var isEmpty: Bool { current.isEmpty && new.isEmpty && confirm.isEmpty }

    func clear() {
        current = ""
        new = ""
        confirm = ""
    }

    /// The rules this key enforces on its own PIN.
    var policy: PinPolicy {
        device().flatMap { devices.state(for: $0.path)?.pinPolicy } ?? PinPolicy()
    }

    /// Why the PIN being typed cannot be submitted yet — in words for the person typing.
    var issue: String? {
        let old = mode == .change && !current.isEmpty ? current : nil
        if let issue = policy.validate(new, oldPIN: old) {
            // "Enter a PIN" under an empty field is noise, not help.
            return issue == .empty ? nil : issue.message
        }
        if !confirm.isEmpty, new != confirm {
            return "The two PINs do not match."
        }
        return nil
    }

    var canSubmit: Bool {
        guard !touchGate.isWorking, issue == nil else { return false }
        guard !new.isEmpty, new == confirm else { return false }
        return mode == .change ? !current.isEmpty : true
    }

    /// Sends the PIN to the key.
    ///
    /// Return can reach here twice — the field's submit action and the default button — and
    /// two attempts must never be spent on one keypress: while one submission is in flight
    /// the next one finds `canSubmit` false and returns without doing anything.
    ///
    /// - Parameter followUp: runs inside the same busy scope once the key has accepted the
    ///   PIN, for the owner to reload what the new PIN now opens before the screen changes.
    /// - Returns: false when nothing was sent. Throws what the key answered; on a failed
    ///   change only the current PIN is cleared, because the failure was about that one and
    ///   retyping a new PIN that was fine is busywork.
    @discardableResult
    func submit(followUp: () async -> Void = {}) async throws -> Bool {
        guard canSubmit, let device = device() else { return false }
        let currentPIN = current
        let newPIN = new
        do {
            try await touchGate.withBusy(mode == .bootstrap ? "Setting the PIN…" : "Changing the PIN…",
                                         surface: surface) {
                switch mode {
                case .bootstrap:
                    try await devices.setInitialPIN(for: device, newPIN: newPIN)
                case .change:
                    try await devices.changePIN(for: device, oldPIN: currentPIN, newPIN: newPIN)
                }
                clear()
                await followUp()
            }
        } catch {
            if mode == .change { current = "" }
            throw error
        }
        return true
    }
}
