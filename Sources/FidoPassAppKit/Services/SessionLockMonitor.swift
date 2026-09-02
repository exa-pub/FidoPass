import AppKit

/// Observes macOS session lock/unlock and notifies listeners.
///
/// Both notification centres deliver on the main queue, which is why the callbacks may
/// assume main-actor isolation rather than hop.
@MainActor
final class SessionLockMonitor {
    private let onLock: () -> Void
    private let onUnlock: (() -> Void)?
    private let center = NSWorkspace.shared.notificationCenter
    private let distributed = DistributedNotificationCenter.default()
    // Observer tokens are removed in `deinit`, which is not isolated; the tokens themselves
    // are never touched from anywhere else.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var distributedObservers: [NSObjectProtocol] = []

    init(onLock: @escaping () -> Void, onUnlock: (() -> Void)? = nil) {
        self.onLock = onLock
        self.onUnlock = onUnlock

        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLock() }
        })

        if onUnlock != nil {
            observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                                object: nil,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onUnlock?() }
            })
        }

        distributedObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                                                            object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLock() }
        })

        if onUnlock != nil {
            distributedObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                                                                object: nil,
                                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onUnlock?() }
            })
        }
    }

    deinit {
        observers.forEach { center.removeObserver($0) }
        distributedObservers.forEach { distributed.removeObserver($0) }
    }
}
