import Foundation

/// Local label history, scoped by credential and compared byte-for-byte.
@MainActor
final class LabelStore: ObservableObject {

    nonisolated static let storageKey = "labelHistory.v2"
    /// Unassigned legacy labels remain on disk until explicitly cleared.
    nonisolated static let legacyStorageKey = "recentLabels"
    /// What an account with no history of its own starts from.
    nonisolated static let fallback = "default"
    nonisolated static let limit = 10
    /// Bound by age, never by whether a key is currently connected.
    nonisolated static let scopeLimit = 32

    /// One account's history, as it goes to disk.
    struct Entry: Codable, Equatable, Identifiable {
        /// Identity. Nil in rows written when history was keyed by vendor/product signature;
        /// such a row remains unassigned until explicitly removed.
        var credentialId: String?
        var accountId: String
        /// Display only, both of them — the key an account lives on, for a settings window
        /// that has to name it while the key itself is in a drawer.
        var deviceSignature: String?
        var deviceName: String?
        var labels: [String]
        var usedAt: Date

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.credentialId == rhs.credentialId && lhs.accountId == rhs.accountId
                && lhs.deviceSignature == rhs.deviceSignature && lhs.deviceName == rhs.deviceName
                && lhs.usedAt == rhs.usedAt && lhs.labels.count == rhs.labels.count
                && zip(lhs.labels, rhs.labels).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
        }

        var id: String { credentialId ?? "legacy|\(deviceSignature ?? "")|\(accountId)" }
    }

    /// The account the HUD is pointed at, or nil when there is none to point at.
    @Published private(set) var scope: LabelScope?
    /// Labels used with `scope`, freshest first.
    @Published private(set) var recent: [String] = []

    private var entries: [Entry] = []
    var onCleared: (() -> Void)?

    var hasLegacyHistory: Bool { userDefaults.object(forKey: Self.legacyStorageKey) != nil }
    var hasHistory: Bool { !entries.isEmpty || hasLegacyHistory }
    nonisolated static let deletionKey = "labelHistory.deletions.v1"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    // MARK: - Reading

    /// Display and keyboard navigation use the same account-scoped list.
    var chips: [String] {
        recent.isEmpty ? [Self.fallback] : Array(recent.prefix(3))
    }

    func labels(for scope: LabelScope) -> [String] {
        entries.first { $0.credentialId == scope.credentialId }?.labels ?? []
    }

    /// Every history on this Mac, freshest first. For the settings window.
    var histories: [Entry] { entries }

    // MARK: - Writing

    /// Points the store at an account. Which label to start from is `LabelEditor`'s decision.
    func focus(_ target: LabelTarget?) {
        scope = target?.scope
        recent = scope.map { labels(for: $0) } ?? []
    }

    /// Records against the operation’s account, independent of the current focus.
    func use(_ label: String, in target: LabelTarget) {
        guard !label.isEmpty else { return }

        let credentialId = target.scope.credentialId
        var entry = entries.first { $0.credentialId == credentialId }
            ?? Entry(credentialId: credentialId, accountId: target.accountId, labels: [], usedAt: .distantPast)
        entry.deviceSignature = target.deviceSignature
        if let name = target.deviceName { entry.deviceName = name }
        entry.labels.removeAll { $0.utf8.elementsEqual(label.utf8) }
        entry.labels.insert(label, at: 0)
        if entry.labels.count > Self.limit { entry.labels.removeLast(entry.labels.count - Self.limit) }
        entry.usedAt = Date()

        entries.removeAll { $0.credentialId == credentialId }
        entries.insert(entry, at: 0)
        entries = Self.trimmed(entries)

        if target.scope == scope {
            recent = entry.labels
        }
        save()
    }

    /// Moves labels after migration, preserving any history already under the new credential.
    func move(from old: LabelScope, to new: LabelScope) {
        guard old != new, let index = entries.firstIndex(where: { $0.credentialId == old.credentialId }) else { return }
        var entry = entries.remove(at: index)
        entry.credentialId = new.credentialId
        entry.usedAt = Date()
        if let existing = entries.firstIndex(where: { $0.credentialId == new.credentialId }) {
            let other = entries.remove(at: existing)
            for label in other.labels where !entry.labels.contains(where: { $0.utf8.elementsEqual(label.utf8) }) {
                entry.labels.append(label)
            }
            entry.labels = Array(entry.labels.prefix(Self.limit))
            entry.usedAt = max(entry.usedAt, other.usedAt)
        }
        entries.insert(entry, at: 0)
        if scope == old {
            scope = new
            recent = entry.labels
        }
        save()
    }

    /// Drops one account's history — called when the account itself is deleted.
    func forget(_ scope: LabelScope) {
        entries.removeAll { $0.credentialId == scope.credentialId }
        if scope == self.scope { recent = [] }
        save()
    }

    /// Clears current and unassigned legacy history from memory and storage.
    func clearAll() {
        userDefaults.removeObject(forKey: Self.legacyStorageKey)
        entries.removeAll()
        recent = []
        save()
        onCleared?()
    }

    // MARK: - Storage

    func load() {
        guard let stored = Self.decode(userDefaults.data(forKey: Self.storageKey)) else {
            entries = []
            return
        }
        entries = stored
        // Consume existing deletion markers before retiring the unused sync format.
        if let data = userDefaults.data(forKey: Self.deletionKey),
           let deletions = try? JSONDecoder().decode(LabelDeletionState.self, from: data) {
            entries.removeAll { !deletions.permits(id: $0.id, usedAt: $0.usedAt) }
            if let cleaned = try? JSONEncoder().encode(entries) {
                userDefaults.set(cleaned, forKey: Self.storageKey)
                userDefaults.removeObject(forKey: Self.deletionKey)
            }
        }
    }

    private static func trimmed(_ entries: [Entry]) -> [Entry] {
        Array(entries.sorted { $0.usedAt == $1.usedAt ? $0.id < $1.id : $0.usedAt > $1.usedAt }.prefix(scopeLimit))
    }

    private static func decode(_ data: Data?) -> [Entry]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}
