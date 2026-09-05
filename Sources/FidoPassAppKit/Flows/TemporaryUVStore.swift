import Foundation
import FidoPassCore

/// An in-memory pause for the current key session. Closing the session forgets it.
@MainActor
final class TemporaryUVStore: ObservableObject {
    enum Phase { case idle, preparing, paused, restoring }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var device: FidoDevice?
    @Published private(set) var deadline: ContinuousClock.Instant?
    @Published private(set) var error: PresentedError?

    private let devices: DeviceStore
    private let gate: TouchGate
    private let duration: Duration
    private var lifetime = OperationLease()
    private var timer: Task<Void, Never>?
    var canBegin: () -> Bool = { true }
    var onConfigurationChanged: ((FidoDevice) async -> Void)?

    init(devices: DeviceStore, gate: TouchGate, duration: Duration = .seconds(60)) {
        self.devices = devices
        self.gate = gate
        self.duration = duration
    }

    func remainingSeconds() -> Int {
        guard let deadline else { return 0 }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        return max(0, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
    }

    func menuTitle(for selected: FidoDevice?) -> String? {
        switch phase {
        case .preparing: return "Pausing Require UV…"
        case .restoring: return "Restoring Require UV…"
        case .paused: return "Restore Require UV now"
        case .idle:
            let state = selected.flatMap { devices.state(for: $0.path) }
            guard state?.alwaysUV == true else { return nil }
            if state?.supportsConfiguration == false { return "Require UV pause unavailable" }
            return "Pause Require UV for 1 minute"
        }
    }

    func canPerformAction(for selected: FidoDevice?) -> Bool {
        guard !gate.isWorking, phase == .idle || phase == .paused,
              let target = device ?? selected, let state = devices.state(for: target.path), state.unlocked else { return false }
        return phase == .paused || (canBegin() && state.supportsConfiguration != false && state.alwaysUV != false)
    }

    func start(for device: FidoDevice) async {
        guard phase == .idle, canPerformAction(for: device) else { return }
        let token = lifetime
        let end = ContinuousClock.now.advanced(by: duration)
        self.device = device
        phase = .preparing
        error = nil
        do {
            let change = try await setAlwaysUV(false, on: device)
            try KeyOperationContext.check(token)
            guard change.changed else { stop(); return }
            var due = end
            if let expiration = devices.pinExpiration(for: device.path) {
                // Try before the cached PIN expires, without extending its lifetime.
                due = min(due, .now.advanced(by: .seconds(max(0, expiration.timeIntervalSinceNow - 5))))
            }
            deadline = due
            phase = .paused
            timer = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: due) } catch { return }
                guard !Task.isCancelled else { return }
                self?.timer = nil
                await self?.restoreIfDue()
            }
        } catch {
            guard token.isValid else { return }
            stop()
            self.error = PresentedError(error)
        }
    }

    func restoreIfDue() async {
        guard let deadline, ContinuousClock.now >= deadline else { return }
        await restore()
    }

    func restore() async {
        guard let device, phase == .paused, !gate.isWorking else { return }
        let token = lifetime
        timer?.cancel()
        timer = nil
        deadline = nil
        phase = .restoring
        error = nil
        do {
            _ = try await setAlwaysUV(true, on: device)
            try KeyOperationContext.check(token)
            stop()
        } catch {
            guard token.isValid else { return }
            phase = .paused
            self.error = PresentedError(error)
        }
    }

    func stop(for path: String? = nil) {
        guard path == nil || device?.path == path else { return }
        lifetime.invalidate()
        lifetime = OperationLease()
        timer?.cancel()
        timer = nil
        device = nil
        deadline = nil
        error = nil
        phase = .idle
    }

    private func setAlwaysUV(_ enabled: Bool, on device: FidoDevice) async throws -> AlwaysUVChange {
        try await gate.withBusy(enabled ? "Restoring Require UV…" : "Pausing Require UV…", surface: .temporaryUV) {
            let change = try await devices.setAlwaysUV(enabled, for: device, extendingPIN: !enabled)
            await onConfigurationChanged?(device)
            return change
        }
    }
}
