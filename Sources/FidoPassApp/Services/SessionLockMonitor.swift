#if os(macOS)
import AppKit

/// Observes macOS session lock/unlock and notifies listeners.
final class SessionLockMonitor {
    private let onLock: () -> Void
    private let onUnlock: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init(onLock: @escaping () -> Void, onUnlock: (() -> Void)? = nil) {
        self.onLock = onLock
        self.onUnlock = onUnlock

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            self?.onLock()
        })

        if let onUnlock {
            observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                                object: nil,
                                                queue: .main) { _ in
                onUnlock()
            })
        }

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                                                            object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.onLock()
        })

        if let onUnlock {
            distributedObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                                                                object: nil,
                                                                queue: .main) { _ in
                onUnlock()
            })
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
        distributedObservers.removeAll()
    }
}
#else
final class SessionLockMonitor {
    init(onLock: @escaping () -> Void, onUnlock: (() -> Void)? = nil) {
        _ = onLock
        _ = onUnlock
    }
}
#endif
