import Foundation

/// Keeps PINs until expiration. Removal overwrites the owned buffer; temporary Swift
/// String/Data copies cannot be guaranteed to have been erased.
///
/// `@unchecked Sendable`: every access to `entries` goes through `queue` with a barrier, and
/// the vault is read synchronously from the key worker's thread — inside a libfido2 callback —
/// which is why it is a class with a queue rather than an actor.
final class SecurePinVault: @unchecked Sendable {
    typealias TimerFactory = (_ queue: DispatchQueue, _ interval: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
    struct Token: Hashable {
        fileprivate let rawValue = UUID()
    }

    /// Guarded by `queue`, hence unchecked.
    private struct Entry: @unchecked Sendable {
        var pinData: Data
        var expiration: Date
        var timer: (@Sendable () -> Void)?
        var generation = UUID()
        var onExpire: (@Sendable () -> Void)?

        mutating func invalidate() {
            timer?()
            timer = nil
            pinData.wipe()
        }
    }

    private let queue: DispatchQueue
    private let timerFactory: TimerFactory
    private var entries: [Token: Entry] = [:]
    private let defaultTTL: TimeInterval
    private let now: @Sendable () -> Date

    init(defaultTTL: TimeInterval = 300,
         queue: DispatchQueue = DispatchQueue(label: "com.fidopass.pinVault", qos: .userInitiated, attributes: .concurrent),
         now: @escaping @Sendable () -> Date = Date.init,
         timerFactory: @escaping TimerFactory = { queue, interval, fire in
             let timer = DispatchSource.makeTimerSource(queue: queue)
             timer.schedule(deadline: .now() + interval)
             timer.setEventHandler(handler: fire)
             timer.resume()
             return { timer.cancel() }
         }) {
        self.defaultTTL = defaultTTL
        self.now = now
        self.queue = queue
        self.timerFactory = timerFactory
    }

    @discardableResult
    func store(pin: String,
               ttl: TimeInterval? = nil,
               onExpire: (@Sendable () -> Void)? = nil) -> Token {
        let token = Token()
        let interval = ttl ?? defaultTTL
        let entry = Entry(pinData: Data(pin.utf8),
                          expiration: now().addingTimeInterval(interval),
                          timer: nil,
                          onExpire: onExpire)

        queue.async(flags: .barrier) {
            var mutableEntry = entry
            self.scheduleTimer(for: token, ttl: interval, entry: &mutableEntry)
            self.entries[token] = mutableEntry
        }
        return token
    }

    func pin(for token: Token, extending ttl: TimeInterval? = nil) -> String? {
        queue.sync(flags: .barrier) { () -> String? in
            guard var entry = entries[token] else { return nil }
            guard entry.expiration > now() else {
                entries[token] = nil
                entry.invalidate()
                handleExpireCallback(for: token, entry: entry)
                return nil
            }

            if let ttl {
                scheduleTimer(for: token, ttl: ttl, entry: &entry)
            }
            entries[token] = entry
            return String(data: entry.pinData, encoding: .utf8)
        }
    }

    /// Observing expiration must neither disclose the PIN nor renew its lifetime.
    func expiration(for token: Token) -> Date? {
        queue.sync { entries[token]?.expiration }
    }

    func extend(token: Token, ttl: TimeInterval? = nil) {
        queue.async(flags: .barrier) {
            guard var entry = self.entries[token] else { return }
            self.scheduleTimer(for: token, ttl: ttl ?? self.defaultTTL, entry: &entry)
            self.entries[token] = entry
        }
    }

    func remove(token: Token) {
        queue.async(flags: .barrier) {
            guard var entry = self.entries.removeValue(forKey: token) else { return }
            entry.invalidate()
        }
    }

    func removeAll() {
        queue.async(flags: .barrier) {
            for key in self.entries.keys {
                var entry = self.entries.removeValue(forKey: key)
                entry?.invalidate()
            }
        }
    }

    private func scheduleTimer(for token: Token, ttl: TimeInterval, entry: inout Entry) {
        entry.timer?()
        entry.timer = nil
        entry.generation = UUID()
        let generation = entry.generation
        guard ttl > 0 else {
            entry.expiration = Date.distantPast
            return
        }
        entry.expiration = now().addingTimeInterval(ttl)
        entry.timer = timerFactory(queue, ttl) { [weak self] in
            self?.handleExpiration(for: token, generation: generation)
        }
    }

    private func handleExpiration(for token: Token, generation: UUID) {
        queue.async(flags: .barrier) {
            guard var entry = self.entries[token], entry.generation == generation, entry.expiration <= self.now() else { return }
            self.entries[token] = nil
            entry.invalidate()
            self.handleExpireCallback(for: token, entry: entry)
        }
    }

    private func handleExpireCallback(for token: Token, entry: Entry) {
        if let onExpire = entry.onExpire {
            DispatchQueue.main.async {
                onExpire()
            }
        }
    }
}

private extension Data {
    mutating func wipe() {
        guard !isEmpty else { return }
        withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
        removeAll(keepingCapacity: false)
    }
}
