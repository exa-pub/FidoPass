import Foundation

/// The label the next password will be derived from, plus the ones used before.
///
/// The label is an input to derivation, not a name: the same key, account and label always
/// produce the same password, and a typo silently produces a different one. Keeping the
/// recent ones one click away is the only protection the app can offer against that.
@MainActor
final class LabelStore: ObservableObject {

    static let storageKey = "recentLabels"
    static let limit = 10

    @Published private(set) var recent: [String] = []
    /// Label the HUD is currently pointed at.
    @Published var current: String = "default"

    private let userDefaults: UserDefaults
    private let ubiStore: NSUbiquitousKeyValueStore
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(userDefaults: UserDefaults = .standard,
         ubiStore: NSUbiquitousKeyValueStore = .default,
         notificationCenter: NotificationCenter = .default) {
        self.userDefaults = userDefaults
        self.ubiStore = ubiStore
        self.notificationCenter = notificationCenter
        load()
        current = recent.first ?? "default"
        observer = notificationCenter.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                  object: ubiStore,
                                                  queue: .main) { [weak self] _ in
            Task { @MainActor in self?.mergeUbiquitous() }
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    func use(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        current = trimmed
        recent.removeAll { $0 == trimmed }
        recent.insert(trimmed, at: 0)
        if recent.count > Self.limit { recent.removeLast(recent.count - Self.limit) }
        save()
    }

    /// Clears the history in memory *and* in storage — wiping only the array left the
    /// values in UserDefaults and iCloud, so they came back on the next launch.
    func clearRecent() {
        recent.removeAll()
        save()
    }

    func load() {
        var local = (userDefaults.array(forKey: Self.storageKey) as? [String]) ?? []
        if let cloud = ubiStore.array(forKey: Self.storageKey) as? [String] {
            for label in cloud.reversed() where !local.contains(label) {
                local.insert(label, at: 0)
            }
        }
        recent = Array(local.prefix(Self.limit))
    }

    func mergeUbiquitous() {
        let before = Set(recent)
        guard let cloud = ubiStore.array(forKey: Self.storageKey) as? [String] else { return }
        var merged = recent
        for label in cloud where !merged.contains(label) { merged.append(label) }
        recent = Array(merged.prefix(Self.limit))
        if Set(recent) != before {
            userDefaults.set(recent, forKey: Self.storageKey)
        }
    }

    private func save() {
        userDefaults.set(recent, forKey: Self.storageKey)
        ubiStore.set(recent, forKey: Self.storageKey)
        ubiStore.synchronize()
    }
}
