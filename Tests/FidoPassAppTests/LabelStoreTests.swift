import XCTest
import FidoPassCore
@testable import FidoPassAppKit
import TestSupport

/// Local history survives relaunch and stays scoped to the credential that used it.
final class LabelStoreTests: AppTestCase {

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

    /// Model and account name cannot identify the owner of legacy history.
    @MainActor
    func testLegacyHistoryRemainsUnassignedUntilItsOwnerIsKnown() {
        let defaults = Self.defaults()
        let older = """
        [{"deviceSignature":"1050:0407","accountId":"vault","labels":["work"],"usedAt":0}]
        """
        defaults.set(Data(older.utf8), forKey: LabelStore.storageKey)

        let store = Self.makeStore(defaults: defaults)
        store.focus(Self.vault)

        XCTAssertTrue(store.recent.isEmpty, "Model and name cannot identify a physical key")
        XCTAssertNil(Self.stored(defaults).first?.credentialId)
        XCTAssertEqual(store.histories.first?.labels, ["work"], "Unassigned labels must be retained")
    }

    /// A different model with the same account name cannot claim legacy labels either.
    @MainActor
    func testAnotherModelCannotClaimLegacyHistory() {
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
        let store = Self.makeStore(defaults: defaults)
        store.use("work", in: Self.vault)

        let reopened = Self.makeStore(defaults: defaults)
        reopened.focus(Self.vault)
        XCTAssertEqual(reopened.recent, ["work"])
    }

    /// Clearing persists across relaunches.
    @MainActor
    func testClearingWipesStorage() {
        let defaults = Self.defaults()
        let store = Self.makeStore(defaults: defaults)
        store.use("work", in: Self.vault)
        store.clearAll()

        XCTAssertTrue(store.histories.isEmpty)
        XCTAssertEqual(Self.stored(defaults), [])
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
    private static func makeStore(defaults: UserDefaults? = nil) -> LabelStore {
        LabelStore(userDefaults: defaults ?? Self.defaults())
    }

    @MainActor
    private static func defaults() -> UserDefaults {
        let suite = "LabelStore-\(UUID().uuidString)"
        let defaults = AppTestFactory.makeDefaults(suite: suite)
        return defaults
    }


    private static func stored(_ defaults: UserDefaults) -> [LabelStore.Entry] {
        guard let data = defaults.data(forKey: LabelStore.storageKey) else { return [] }
        return (try? JSONDecoder().decode([LabelStore.Entry].self, from: data)) ?? []
    }

}


@MainActor
extension LabelStoreTests {
    func testClearAllMustRemoveLegacyLabelStorage() {
        let suite = "LabelStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["public-label"], forKey: LabelStore.legacyStorageKey)
        let store = LabelStore(userDefaults: defaults)
        store.clearAll()
        XCTAssertNil(defaults.object(forKey: LabelStore.legacyStorageKey), "Legacy local history survived clear")
    }

    func testLabelHistoryMustRetainByteDistinctDerivationInputs() {
        let suite = "LabelStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LabelStore(userDefaults: defaults)
        let target = LabelTarget(scope: LabelScope(credentialId: "public-credential"),
                                 accountId: "vault", deviceSignature: "mock", deviceName: "Mock")
        store.use("é", in: target)
        store.use("e\u{0301}", in: target)
        XCTAssertEqual(store.labels(for: target.scope).count, 2, "Different salts collapsed into one historical label")
    }
}

@MainActor
extension LabelStoreTests {
    func testStoredDeletionMarkersAreAppliedAndRetired() throws {
        let defaults = Self.defaults()
        let entries = [
            LabelStore.Entry(credentialId: Self.vault.scope.credentialId, accountId: "vault",
                             labels: ["old"], usedAt: Date(timeIntervalSinceReferenceDate: 99)),
            LabelStore.Entry(credentialId: Self.disk.scope.credentialId, accountId: "disk",
                             labels: ["deleted"], usedAt: Date(timeIntervalSinceReferenceDate: 102)),
            LabelStore.Entry(credentialId: Self.vaultOnSpare.scope.credentialId, accountId: "vault",
                             labels: ["kept"], usedAt: Date(timeIntervalSinceReferenceDate: 104))
        ]
        let markers = LabelDeletionState(clearedAt: Date(timeIntervalSinceReferenceDate: 100),
                                         scopes: [Self.disk.scope.credentialId: Date(timeIntervalSinceReferenceDate: 103)])
        defaults.set(try JSONEncoder().encode(entries), forKey: LabelStore.storageKey)
        defaults.set(try JSONEncoder().encode(markers), forKey: LabelStore.deletionKey)

        let store = Self.makeStore(defaults: defaults)
        XCTAssertEqual(store.histories.map(\.labels), [["kept"]])
        XCTAssertEqual(Self.stored(defaults), store.histories)
        XCTAssertNil(defaults.data(forKey: LabelStore.deletionKey))

        store.use("new", in: Self.vault)
        let reopened = Self.makeStore(defaults: defaults)
        XCTAssertEqual(reopened.labels(for: Self.vault.scope), ["new"])
        XCTAssertEqual(reopened.labels(for: Self.vaultOnSpare.scope), ["kept"])
        store.forget(Self.vault.scope)
        XCTAssertTrue(Self.makeStore(defaults: defaults).labels(for: Self.vault.scope).isEmpty)
    }

    func testMalformedDeletionMarkersDoNotEraseHistory() {
        let defaults = Self.defaults()
        let store = Self.makeStore(defaults: defaults)
        store.use("kept", in: Self.vault)
        let malformed = Data("invalid".utf8)
        defaults.set(malformed, forKey: LabelStore.deletionKey)

        XCTAssertEqual(Self.makeStore(defaults: defaults).labels(for: Self.vault.scope), ["kept"])
        XCTAssertEqual(defaults.data(forKey: LabelStore.deletionKey), malformed)
    }

    func testMalformedHistoryIsNotOverwrittenWhenRetiringDeletionMarkers() throws {
        let defaults = Self.defaults()
        let malformed = Data("unreadable-history".utf8)
        let markers = try JSONEncoder().encode(LabelDeletionState(clearedAt: Date()))
        defaults.set(malformed, forKey: LabelStore.storageKey)
        defaults.set(markers, forKey: LabelStore.deletionKey)

        XCTAssertTrue(Self.makeStore(defaults: defaults).histories.isEmpty)
        XCTAssertEqual(defaults.data(forKey: LabelStore.storageKey), malformed)
        XCTAssertEqual(defaults.data(forKey: LabelStore.deletionKey), markers)
    }

}
