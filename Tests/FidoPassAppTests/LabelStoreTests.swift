import XCTest
import FidoPassCore
@testable import FidoPassAppKit
import TestSupport

/// Labels are not secret, but forgetting one makes its password unreproducible — so the
/// history has to survive relaunches, merge across devices, never quietly come back after
/// the user clears it, and, above all, stay with the account it belongs to: a label offered
/// for the wrong account derives a perfectly valid, perfectly wrong password.
final class LabelStoreTests: XCTestCase {

    private static let vault = target("cred-vault", account: "vault")
    private static let disk = target("cred-disk", account: "disk")
    /// The same account id on a second key — what a portable backup looks like. Same id,
    /// different credential, different history.
    private static let vaultOnSpare = target("cred-vault-spare",
                                             account: "vault",
                                             signature: "1050:0402",
                                             name: "Yubico YubiKey FIDO")

    @MainActor
    func testHistoryIsKeptPerAccount() {
        let store = Self.makeStore()
        store.use("work", in: Self.vault)
        store.use("disk-key", in: Self.disk)

        store.focus(Self.vault)
        XCTAssertEqual(store.recent, ["work"])
        XCTAssertFalse(store.chips.contains("disk-key"), "another account's label must not be one click away")
        XCTAssertEqual(store.chips, ["work"])

        store.focus(Self.disk)
        XCTAssertEqual(store.recent, ["disk-key"])
    }

    /// The same account id on two keys is two credentials, so it is two histories. Merging
    /// them would put a local account's labels under a different key's account.
    @MainActor
    func testTheSameAccountIdOnTwoKeysIsTwoHistories() {
        let store = Self.makeStore()
        store.use("here", in: Self.vault)
        store.use("there", in: Self.vaultOnSpare)

        XCTAssertEqual(store.labels(for: Self.vault.scope), ["here"])
        XCTAssertEqual(store.labels(for: Self.vaultOnSpare.scope), ["there"])
    }

    /// Writing goes to the target it is given, not to whatever happens to be focused: the
    /// password was derived for one specific account, and a lost label is a lost password.
    @MainActor
    func testWritingIgnoresTheFocusedScope() {
        let store = Self.makeStore()
        store.focus(Self.disk)
        store.use("work", in: Self.vault)

        XCTAssertEqual(store.recent, [], "the focused account has no history of its own")
        XCTAssertEqual(store.labels(for: Self.vault.scope), ["work"])
    }

    @MainActor
    func testUsingALabelDeduplicatesAndCaps() {
        let store = Self.makeStore()
        store.focus(Self.vault)
        for index in 0..<12 { store.use("label-\(index)", in: Self.vault) }
        store.use("label-5", in: Self.vault)

        XCTAssertEqual(store.recent.first, "label-5")
        XCTAssertEqual(store.recent.count, LabelStore.limit)
    }

    /// Whitespace around a label would derive a different password from the one the user
    /// thinks they typed.
    @MainActor
    func testLabelsAreTrimmedAndBlanksIgnored() {
        let store = Self.makeStore()
        store.focus(Self.vault)
        store.use("  work  ", in: Self.vault)
        XCTAssertEqual(store.recent, ["work"])

        store.use("   ", in: Self.vault)
        XCTAssertEqual(store.recent, ["work"], "a blank label is not a label")
    }

    // MARK: - Accounts with no history yet

    /// A fresh account is offered the conventional default and nothing else. A label used
    /// with another account — or with the same account id on another key — derives a valid,
    /// wrong password here, and one chip away is far too close for that.
    @MainActor
    func testAnAccountWithNoHistoryStartsFromTheDefault() {
        let store = Self.makeStore()
        store.use("work", in: Self.disk)
        store.use("twin", in: Self.vaultOnSpare)
        store.focus(Self.vault)

        XCTAssertEqual(store.recent, [])
        XCTAssertEqual(store.chips, [LabelStore.fallback])
    }

    @MainActor
    func testTheDefaultChipIsNotAStoredLabel() {
        let defaults = Self.defaults()
        let store = Self.makeStore(defaults: defaults)
        store.focus(Self.vault)
        XCTAssertEqual(store.chips, ["default"])

        XCTAssertEqual(Self.stored(defaults), [], "shown, not recorded")
        store.use("own", in: Self.vault)
        XCTAssertEqual(store.chips, ["own"], "and the first real use replaces it")
    }

    /// The single global list earlier versions kept cannot be attributed to any account, so
    /// it is not read at all. It stays on disk: a label is unrecoverable once lost, and
    /// deleting the last record of one is not this app's call.
    @MainActor
    func testTheLegacyGlobalListIsNeitherReadNorDeleted() {
        let defaults = Self.defaults()
        defaults.set(["from-before"], forKey: LabelStore.legacyStorageKey)
        let store = Self.makeStore(defaults: defaults)
        store.focus(Self.vault)

        XCTAssertEqual(store.chips, ["default"])
        XCTAssertEqual(defaults.array(forKey: LabelStore.legacyStorageKey) as? [String], ["from-before"])
    }

    // MARK: - Migration

    /// A migrated account is a new credential. Its labels are the one thing about the old
    /// one that cannot be derived again, so they move with it — merging with anything
    /// already recorded under the new credential.
    @MainActor
    func testAHistoryMovesToTheMigratedCredential() {
        let defaults = Self.defaults()
        let store = Self.makeStore(defaults: defaults)
        store.use("work", in: Self.vault)
        store.use("archive", in: Self.vaultOnSpare)
        store.focus(Self.vault)

        store.move(from: Self.vault.scope, to: Self.vaultOnSpare.scope)

        XCTAssertEqual(store.labels(for: Self.vault.scope), [], "nothing is left under the old credential")
        XCTAssertEqual(store.labels(for: Self.vaultOnSpare.scope), ["work", "archive"], "the histories are merged, the moved one first")
        XCTAssertEqual(store.scope, Self.vaultOnSpare.scope, "the focus follows the account")
        XCTAssertEqual(store.recent, ["work", "archive"])
        XCTAssertEqual(Self.stored(defaults).map(\.credentialId), ["cred-vault-spare"], "and it is on disk")
    }

    @MainActor
    func testMovingANonexistentHistoryDoesNothing() {
        let defaults = Self.defaults()
        let store = Self.makeStore(defaults: defaults)
        store.use("work", in: Self.vaultOnSpare)
        store.move(from: Self.vault.scope, to: Self.vaultOnSpare.scope)
        XCTAssertEqual(store.labels(for: Self.vaultOnSpare.scope), ["work"])
    }

    // MARK: - Identity

    /// The key's name is recorded so the settings window can say which key an account lives
    /// on while that key is in a drawer.
    @MainActor
    func testTheKeysNameAndSignatureAreRecordedForDisplay() {
        let defaults = Self.defaults()
        let store = Self.makeStore(defaults: defaults)
        store.use("work", in: Self.vault)

        let written = Self.stored(defaults).first
        XCTAssertEqual(written?.credentialId, "cred-vault")
        XCTAssertEqual(written?.accountId, "vault")
        XCTAssertEqual(written?.deviceName, "Yubico YubiKey 5")
        XCTAssertEqual(written?.deviceSignature, "1050:0407")
    }

    /// Histories written when the key was identified by vendor/product signature are claimed
    /// by the credential they turn out to belong to. Dropping them would lose labels, and a
    /// lost label is a password nobody can derive again.
    @MainActor
    func testAHistoryFromTheOldSignatureSchemeIsAdopted() {
        let defaults = Self.defaults()
        let older = """
        [{"deviceSignature":"1050:0407","accountId":"vault","labels":["work"],"usedAt":0}]
        """
        defaults.set(Data(older.utf8), forKey: LabelStore.storageKey)

        let store = Self.makeStore(defaults: defaults)
        store.focus(Self.vault)

        XCTAssertEqual(store.recent, ["work"], "the old history is this account's")
        XCTAssertEqual(Self.stored(defaults).first?.credentialId, "cred-vault", "and is re-keyed on disk")
    }

    /// Adoption matches on the old key, not on the account id alone: the same id on another
    /// key is a different credential and a different history.
    @MainActor
    func testAdoptionDoesNotClaimAnotherKeysHistory() {
        let defaults = Self.defaults()
        let older = """
        [{"deviceSignature":"1050:0407","accountId":"vault","labels":["work"],"usedAt":0}]
        """
        defaults.set(Data(older.utf8), forKey: LabelStore.storageKey)

        let store = Self.makeStore(defaults: defaults)
        store.focus(Self.vaultOnSpare)

        XCTAssertEqual(store.recent, [])
        XCTAssertNil(Self.stored(defaults).first?.credentialId)
    }

    // MARK: - Bounds

    /// Histories are never dropped because an account is out of sight — a key that is not
    /// plugged in proves nothing. Only the oldest ones go, and only past the cap.
    @MainActor
    func testTheNumberOfHistoriesIsCappedOldestFirst() {
        let store = Self.makeStore()
        store.use("first", in: Self.vault)
        for index in 0..<LabelStore.scopeLimit {
            store.use("l", in: Self.target("cred-\(index)", account: "acc-\(index)"))
        }

        XCTAssertEqual(store.histories.count, LabelStore.scopeLimit)
        XCTAssertEqual(store.labels(for: Self.vault.scope), [], "the oldest history is the one that goes")
    }

    // MARK: - Storage

    @MainActor
    func testHistoriesSurviveARelaunch() {
        let defaults = Self.defaults()
        let cloud = InMemoryUbiquitousStore()
        let store = Self.makeStore(defaults: defaults, cloud: cloud)
        store.use("work", in: Self.vault)

        let reopened = Self.makeStore(defaults: defaults, cloud: cloud)
        reopened.focus(Self.vault)
        XCTAssertEqual(reopened.recent, ["work"])
    }

    /// A conflict between two Macs must not lose a label on either side.
    @MainActor
    func testMergeUnionsEachAccountSeparately() {
        let defaults = Self.defaults()
        let cloud = InMemoryUbiquitousStore()
        let store = Self.makeStore(defaults: defaults, cloud: cloud)
        store.use("local", in: Self.vault)

        Self.seedCloud(cloud, [(Self.vault, ["remote"]), (Self.disk, ["other-mac"])])
        store.mergeUbiquitous()

        store.focus(Self.vault)
        XCTAssertEqual(store.recent, ["local", "remote"])
        XCTAssertEqual(store.labels(for: Self.disk.scope), ["other-mac"], "a history only the other Mac had arrives whole")
        XCTAssertEqual(Self.stored(defaults).count, 2, "and the merge is written down, not just shown")
    }

    /// Clearing only the in-memory list used to leave the values in UserDefaults and iCloud,
    /// so they reappeared on the next launch.
    @MainActor
    func testClearingWipesStorage() {
        let defaults = Self.defaults()
        let cloud = InMemoryUbiquitousStore()
        let store = Self.makeStore(defaults: defaults, cloud: cloud)
        store.use("work", in: Self.vault)
        store.clearAll()

        XCTAssertTrue(store.histories.isEmpty)
        XCTAssertEqual(Self.stored(defaults), [])
        XCTAssertEqual(Self.decodeCloud(cloud), [])
    }

    @MainActor
    func testForgettingOneAccountLeavesTheOthers() {
        let store = Self.makeStore()
        store.use("work", in: Self.vault)
        store.use("disk-key", in: Self.disk)

        store.forget(Self.vault.scope)
        XCTAssertEqual(store.labels(for: Self.vault.scope), [])
        XCTAssertEqual(store.labels(for: Self.disk.scope), ["disk-key"])
    }

    // MARK: - Helpers

    private static func target(_ credentialId: String,
                               account: String,
                               signature: String = "1050:0407",
                               name: String? = "Yubico YubiKey 5") -> LabelTarget {
        LabelTarget(scope: LabelScope(credentialId: credentialId),
                    accountId: account,
                    deviceSignature: signature,
                    deviceName: name)
    }

    @MainActor
    private static func makeStore(defaults: UserDefaults? = nil,
                                  cloud: InMemoryUbiquitousStore = InMemoryUbiquitousStore()) -> LabelStore {
        LabelStore(userDefaults: defaults ?? Self.defaults(),
                   ubiStore: cloud,
                   notificationCenter: NotificationCenter())
    }

    private static func defaults() -> UserDefaults {
        let suite = "LabelStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func decodeCloud(_ cloud: InMemoryUbiquitousStore) -> [LabelStore.Entry] {
        guard let data = cloud.data(forKey: LabelStore.storageKey) else { return [] }
        return (try? JSONDecoder().decode([LabelStore.Entry].self, from: data)) ?? []
    }

    private static func stored(_ defaults: UserDefaults) -> [LabelStore.Entry] {
        guard let data = defaults.data(forKey: LabelStore.storageKey) else { return [] }
        return (try? JSONDecoder().decode([LabelStore.Entry].self, from: data)) ?? []
    }

    private static func seedCloud(_ cloud: InMemoryUbiquitousStore, _ values: [(LabelTarget, [String])]) {
        let entries = values.map {
            LabelStore.Entry(credentialId: $0.0.scope.credentialId,
                             accountId: $0.0.accountId,
                             deviceSignature: $0.0.deviceSignature,
                             deviceName: $0.0.deviceName,
                             labels: $0.1,
                             usedAt: Date())
        }
        cloud.set(try! JSONEncoder().encode(entries), forKey: LabelStore.storageKey)
    }
}

/// What the app is allowed to remember between launches.
final class PreferencesTests: XCTestCase {

    @MainActor
    func testLastUsedSurvivesAReconnectByVendorAndProduct() {
        let preferences = Preferences(defaults: Self.defaults())
        let device = MockKeyBackend.device(path: "/dev/one")
        preferences.remember(accountId: "vault", label: "work", device: device)

        // Same key, new session handle: the memory has to still apply.
        let reconnected = MockKeyBackend.device(path: "/dev/whatever-else")
        XCTAssertEqual(preferences.lastUsed?.deviceSignature, reconnected.modelSignature)
    }

    /// The account id is the only piece of account data that reaches the disk, and it is
    /// opt-out — turning the switch off must erase what was already written.
    @MainActor
    func testTurningOffTheMemoryForgetsWhatWasStored() {
        let defaults = Self.defaults()
        let preferences = Preferences(defaults: defaults)
        preferences.remember(accountId: "vault", label: "work", device: MockKeyBackend.device())
        XCTAssertNotNil(preferences.lastUsed)

        preferences.rememberLastUsed = false
        XCTAssertNil(preferences.lastUsed)
        XCTAssertNil(defaults.data(forKey: "hud.lastUsed"))

        preferences.remember(accountId: "vault", label: "work", device: MockKeyBackend.device())
        XCTAssertNil(preferences.lastUsed, "with the switch off, nothing new may be recorded either")
    }

    /// The timeout is what stands between "unlocked" and "anyone at this Mac can generate
    /// this vault's master password", so it has to survive a relaunch exactly as chosen.
    @MainActor
    func testLockTimeoutIsRememberedAndFallsBackToAKnownValue() {
        let defaults = Self.defaults()
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.lockTimeout, 300)

        preferences.lockTimeout = 900
        XCTAssertEqual(Preferences(defaults: defaults).lockTimeout, 900)

        // A value from a future version, or a hand-edited plist, must not become a timeout
        // nobody can see or change in the picker.
        defaults.set(7.0, forKey: "hud.lockTimeout")
        XCTAssertEqual(Preferences(defaults: defaults).lockTimeout, 300)
    }

    private static func defaults() -> UserDefaults {
        let suite = "Preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
