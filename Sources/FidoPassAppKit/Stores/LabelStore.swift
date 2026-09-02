import Foundation

/// The label the next password will be derived from, plus the ones used before — kept per
/// account rather than in one global list.
///
/// The label is an input to derivation, not a name: the same key, account and label always
/// produce the same password, and a typo silently produces a different one. Keeping the
/// recent ones one click away is the only protection the app can offer against that, and a
/// chip is only protection if it belongs to the account it is offered for: `disk` next to
/// `vault` derives a perfectly valid, perfectly wrong password.
@MainActor
final class LabelStore: ObservableObject {

    nonisolated static let storageKey = "labelHistory.v2"
    /// The single global list earlier versions kept. Never read and never written: there is
    /// nothing to attribute it to, and offering one account's labels under another is the
    /// mistake this store now exists to prevent. It is left on disk rather than deleted —
    /// a label is not recoverable once lost, so removing the only remaining record of one
    /// is not the app's call to make.
    nonisolated static let legacyStorageKey = "recentLabels"
    /// What an account with no history of its own starts from.
    nonisolated static let fallback = "default"
    nonisolated static let limit = 10
    /// Histories are never dropped because an account is "not there": an account is only
    /// visible while its key is plugged in and unlocked, so absence proves nothing. This is
    /// the only automatic bound — oldest first, and far out of reach for the one or two keys
    /// this app is built around.
    nonisolated static let scopeLimit = 32

    /// One account's history, as it goes to disk.
    struct Entry: Codable, Equatable, Identifiable {
        /// Identity. Nil in rows written when history was keyed by vendor/product signature;
        /// such a row is adopted the first time its account is seen again.
        var credentialId: String?
        var accountId: String
        /// Display only, both of them — the key an account lives on, for a settings window
        /// that has to name it while the key itself is in a drawer.
        var deviceSignature: String?
        var deviceName: String?
        var labels: [String]
        var usedAt: Date

        var id: String { credentialId ?? "legacy|\(deviceSignature ?? "")|\(accountId)" }
    }

    /// The account the HUD is pointed at, or nil when there is none to point at.
    @Published private(set) var scope: LabelScope?
    /// Labels used with `scope`, freshest first.
    @Published private(set) var recent: [String] = []
    /// Label the HUD is currently pointed at.
    @Published var current: String = "default"

    private var entries: [Entry] = []

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
        current = Self.fallback
        observer = notificationCenter.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                  object: ubiStore,
                                                  queue: .main) { [weak self] _ in
            Task { @MainActor in self?.mergeUbiquitous() }
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    // MARK: - Reading

    /// The labels shown as chips. The keyboard walks exactly this list, so it and the view
    /// can never disagree about what comes next.
    ///
    /// An account with no history of its own offers the conventional default and nothing
    /// else. It is never shown a label used elsewhere — not from another account, not from
    /// the same account on another key: under the wrong account that label derives a
    /// password that is valid and wrong, and one chip away is far too close for that.
    var chips: [String] {
        recent.isEmpty ? [Self.fallback] : Array(recent.prefix(3))
    }

    func labels(for scope: LabelScope) -> [String] {
        entries.first { $0.credentialId == scope.credentialId }?.labels ?? []
    }

    /// Every history on this Mac, freshest first. For the settings window.
    var histories: [Entry] { entries }

    // MARK: - Writing

    /// Points the store at an account. `current` is not touched here — it is `HUDStore` that
    /// decides what the label should be, through `HUDReducer.resolveLabel`.
    func focus(_ target: LabelTarget?) {
        if let target { adoptLegacyEntry(for: target) }
        scope = target?.scope
        recent = scope.map { labels(for: $0) } ?? []
    }

    /// Claims a history written before scopes were keyed by credential.
    ///
    /// The old key was the vendor/product signature plus the account id, and that is exactly
    /// what is matched here — the first time the account is seen with its credential in hand.
    /// Labels are not recoverable once lost, so these rows are re-keyed rather than dropped.
    private func adoptLegacyEntry(for target: LabelTarget) {
        guard !entries.contains(where: { $0.credentialId == target.scope.credentialId }) else { return }
        guard let index = entries.firstIndex(where: { $0.credentialId == nil
            && $0.accountId == target.accountId
            && $0.deviceSignature == target.deviceSignature }) else { return }
        entries[index].credentialId = target.scope.credentialId
        if entries[index].deviceName == nil { entries[index].deviceName = target.deviceName }
        save()
    }

    /// Records a label against an account.
    ///
    /// The scope is passed in rather than read from `focus`: a password has just been
    /// derived for a specific account, and the write must not depend on whether a focus
    /// change has landed yet. A label that fails to be recorded is a password that cannot
    /// be reproduced.
    func use(_ label: String, in target: LabelTarget) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        adoptLegacyEntry(for: target)

        let credentialId = target.scope.credentialId
        var entry = entries.first { $0.credentialId == credentialId }
            ?? Entry(credentialId: credentialId, accountId: target.accountId, labels: [], usedAt: .distantPast)
        entry.deviceSignature = target.deviceSignature
        if let name = target.deviceName { entry.deviceName = name }
        entry.labels.removeAll { $0 == trimmed }
        entry.labels.insert(trimmed, at: 0)
        if entry.labels.count > Self.limit { entry.labels.removeLast(entry.labels.count - Self.limit) }
        entry.usedAt = Date()

        entries.removeAll { $0.credentialId == credentialId }
        entries.insert(entry, at: 0)
        entries = Self.trimmed(entries)

        if target.scope == scope {
            recent = entry.labels
            current = trimmed
        }
        save()
    }

    /// Drops one account's history — called when the account itself is deleted.
    func forget(_ scope: LabelScope) {
        guard entries.contains(where: { $0.credentialId == scope.credentialId }) else { return }
        entries.removeAll { $0.credentialId == scope.credentialId }
        if scope == self.scope { recent = [] }
        save()
    }

    /// Clears every history in memory *and* in storage, the legacy list included — wiping
    /// only the arrays left the values on disk, so they came back on the next launch.
    func clearAll() {
        entries.removeAll()
        recent = []
        save()
    }

    // MARK: - Storage

    func load() {
        entries = Self.decode(userDefaults.data(forKey: Self.storageKey)) ?? []
        if let remote = Self.decode(ubiStore.data(forKey: Self.storageKey)) {
            entries = Self.merge(local: entries, remote: remote)
        }
    }

    func mergeUbiquitous() {
        guard let remote = Self.decode(ubiStore.data(forKey: Self.storageKey)) else { return }
        let merged = Self.merge(local: entries, remote: remote)
        guard merged != entries else { return }
        entries = merged
        if let scope { recent = labels(for: scope) }
        if let data = try? JSONEncoder().encode(entries) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Union per account: a conflict between two Macs must not lose a label on either side,
    /// which matters more than the exact order they end up in.
    static func merge(local: [Entry], remote: [Entry]) -> [Entry] {
        var result = local
        for var incoming in remote {
            if let index = result.firstIndex(where: { $0.id == incoming.id }) {
                var entry = result[index]
                for label in incoming.labels where !entry.labels.contains(label) { entry.labels.append(label) }
                if entry.deviceName == nil { entry.deviceName = incoming.deviceName }
                entry.labels = Array(entry.labels.prefix(limit))
                entry.usedAt = max(entry.usedAt, incoming.usedAt)
                result[index] = entry
            } else {
                incoming.labels = Array(incoming.labels.prefix(limit))
                result.append(incoming)
            }
        }
        return trimmed(result)
    }

    private static func trimmed(_ entries: [Entry]) -> [Entry] {
        Array(entries.sorted { $0.usedAt > $1.usedAt }.prefix(scopeLimit))
    }

    private static func decode(_ data: Data?) -> [Entry]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
        ubiStore.set(data, forKey: Self.storageKey)
        ubiStore.synchronize()
    }
}
