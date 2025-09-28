import Foundation

/// Stores PIN codes in memory with automatic expiration and zeroisation on removal.
final class SecurePinVault {
    struct Token: Hashable {
        fileprivate let rawValue = UUID()
    }

    private struct Entry {
        var pinData: Data
        var expiration: Date
        var timer: DispatchSourceTimer?
        var onExpire: (() -> Void)?

        mutating func invalidate() {
            timer?.cancel()
            timer = nil
            pinData.wipe()
        }
    }

    private let queue = DispatchQueue(label: "com.fidopass.pinVault", qos: .userInitiated, attributes: .concurrent)
    private var entries: [Token: Entry] = [:]
    private let defaultTTL: TimeInterval

    init(defaultTTL: TimeInterval = 300) {
        self.defaultTTL = defaultTTL
    }

    @discardableResult
    func store(pin: String,
               ttl: TimeInterval? = nil,
               onExpire: (() -> Void)? = nil) -> Token {
        let token = Token()
        let interval = ttl ?? defaultTTL
        let entry = Entry(pinData: Data(pin.utf8),
                          expiration: Date().addingTimeInterval(interval),
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
            guard entry.expiration > Date() else {
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
        entry.timer?.cancel()
        entry.timer = nil
        guard ttl > 0 else {
            entry.expiration = Date.distantPast
            return
        }
        entry.expiration = Date().addingTimeInterval(ttl)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + ttl)
        timer.setEventHandler { [weak self] in
            self?.handleExpiration(for: token)
        }
        timer.resume()
        entry.timer = timer
    }

    private func handleExpiration(for token: Token) {
        queue.async(flags: .barrier) {
            guard var entry = self.entries.removeValue(forKey: token) else { return }
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
            memset(base, 0, buffer.count)
        }
        removeAll(keepingCapacity: false)
    }
}
