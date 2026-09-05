import XCTest
@testable import FidoPassAppKit
import FidoPassCore
import TestSupport

/// The receiving window: pasting finds the account and touches nothing; the button is the
/// touch, once per nonce; closing leaves nothing behind.
@MainActor
final class MessageDecryptStoreTests: AppTestCase {

    @MainActor
    private struct Setup {
        let panel: PanelStore
        let backend: MockKeyBackend
        let device: FidoDevice
        let store: MessageDecryptStore

        func account(_ id: String) throws -> AccountHandle {
            try XCTUnwrap(panel.accounts.account(AccountRef(accountId: id, devicePath: device.path)))
        }
    }

    private func setUpStore(accounts: [Account]? = nil) async -> Setup {
        let (panel, backend, device) = await AppTestFactory.unlockedStore(accounts: accounts)
        let store = MessageDecryptStore(accounts: panel.accounts,
                                        touchGate: panel.touchGate,
                                        devicePath: device.path,
                                        deviceName: device.displayName)
        return Setup(panel: panel, backend: backend, device: device, store: store)
    }

    private func settle(_ store: MessageDecryptStore) async throws {
        try await waitUntil { !store.isParsing && store.status != .locating }
    }

    // MARK: - Reading a message

    func testPastingFindsTheAccountWithoutTouchingTheKey() async throws {
        let setup = await setUpStore()
        let message = try setup.backend.sealedMessage("hello", for: try setup.account("vault"))

        setup.store.sealedText = message.absoluteString
        try await settle(setup.store)

        XCTAssertEqual(setup.store.status, .ready(accountId: "vault"))
        XCTAssertEqual(setup.store.message, message)
        XCTAssertTrue(setup.backend.deriveMessageKeyCalls.isEmpty, "finding the account is not a request to the key")
        XCTAssertTrue(setup.store.canDecrypt)
    }

    func testAPrefixIsIncompleteNotWrong() async throws {
        let setup = await setUpStore()
        let message = try setup.backend.sealedMessage("hello", for: try setup.account("vault"))

        setup.store.sealedText = String(message.absoluteString.prefix(80))
        XCTAssertEqual(setup.store.status, .incomplete)
        XCTAssertFalse(setup.store.canDecrypt)
    }

    func testAKeyLinkIsNamedAsSuch() async throws {
        let setup = await setUpStore()
        setup.store.sealedText = try setup.backend.encryptionKey(for: try setup.account("vault")).absoluteString
        try await settle(setup.store)
        XCTAssertEqual(setup.store.status, .invalid(.unexpectedKind("hpkev1")))
    }

    func testAMessageForAnotherKeyFindsNoAccount() async throws {
        let setup = await setUpStore()
        let elsewhere = AccountHandle.fixture(id: "vault", credentialId: Data("another-key".utf8), devicePath: "/dev/other")
        let message = try setup.backend.sealedMessage("hello", for: elsewhere)

        setup.store.sealedText = message.absoluteString
        try await settle(setup.store)

        XCTAssertEqual(setup.store.status, .noMatchingAccount)
        XCTAssertFalse(setup.store.hasLegacyAccounts)
    }

    /// An account from before identities has no locator, so no message can find it. The
    /// window says so instead of leaving "no account" unexplained.
    func testLegacyAccountsAreMentionedWhenNothingMatches() async throws {
        let setup = await setUpStore(accounts: [Account.portableFixture(id: "old", legacy: true),
                                                Account.fixture(id: "disk", kind: .local)])
        let elsewhere = AccountHandle.fixture(id: "old", credentialId: Data("another-key".utf8), devicePath: "/dev/other")
        setup.store.sealedText = try setup.backend.sealedMessage("hello", for: elsewhere).absoluteString
        try await settle(setup.store)

        XCTAssertEqual(setup.store.status, .noMatchingAccount)
        XCTAssertTrue(setup.store.hasLegacyAccounts)
    }

    // MARK: - Decrypting

    func testDecryptingIsOneTouchPerNonce() async throws {
        let setup = await setUpStore()
        let vault = try setup.account("vault")

        setup.store.sealedText = try setup.backend.sealedMessage("first", for: vault).absoluteString
        try await settle(setup.store)
        await setup.store.decrypt()
        XCTAssertEqual(setup.store.plaintext, "first")
        XCTAssertEqual(setup.store.status, .decrypted(accountId: "vault"))
        XCTAssertEqual(setup.backend.deriveMessageKeyCalls.count, 1)

        // Another message under the same key: the key is already here.
        setup.store.sealedText = try setup.backend.sealedMessage("second", for: vault).absoluteString
        XCTAssertTrue(setup.store.plaintext.isEmpty, "a new message replaces the old text at once")
        try await settle(setup.store)
        await setup.store.decrypt()
        XCTAssertEqual(setup.store.plaintext, "second")
        XCTAssertEqual(setup.backend.deriveMessageKeyCalls.count, 1, "the same nonce must not cost a second touch")

        // A message under another key of the same account: another nonce, another touch.
        let otherNonce = Data(repeating: 0xA5, count: 32)
        setup.store.sealedText = try setup.backend.sealedMessage("third", for: vault, nonce: otherNonce).absoluteString
        try await settle(setup.store)
        await setup.store.decrypt()
        XCTAssertEqual(setup.store.plaintext, "third")
        XCTAssertEqual(setup.backend.deriveMessageKeyCalls.count, 2)
        XCTAssertEqual(setup.backend.deriveMessageKeyCalls.last?.nonce, otherNonce)
    }

    /// The prompt is the window's, not the panel's: the panel neither shows it nor is held
    /// open by it.
    func testTheTouchPromptBelongsToTheWindow() async throws {
        let setup = await setUpStore()
        let gate = BlockingGate()
        defer { gate.open() }
        setup.backend.deriveMessageKeyGate = gate
        setup.store.sealedText = try setup.backend.sealedMessage("hello", for: try setup.account("vault")).absoluteString
        try await settle(setup.store)

        let decrypting = Task { await setup.store.decrypt() }
        try await waitUntil { gate.hasEntered }
        XCTAssertNotNil(setup.store.touch)
        XCTAssertNil(setup.panel.touch, "the panel must not draw the receiving window's prompt")
        XCTAssertFalse(setup.panel.touchGate.isPanelBusy)
        XCTAssertTrue(setup.panel.isWorking, "but one key operation at a time, app-wide")

        gate.open()
        await decrypting.value
        XCTAssertEqual(setup.store.plaintext, "hello")
        XCTAssertNil(setup.store.touch)
    }

    func testAnAlteredMessageIsUnreadableAndSaysSo() async throws {
        let setup = await setUpStore()
        let genuine = try setup.backend.sealedMessage("hello", for: try setup.account("vault"))
        var content = genuine.content
        content[content.startIndex + 40] ^= 0x01
        let altered = try SealedMessageURL(nonce: genuine.nonce, locator: genuine.locator, content: content)

        setup.store.sealedText = altered.absoluteString
        try await settle(setup.store)
        await setup.store.decrypt()

        XCTAssertTrue(setup.store.plaintext.isEmpty)
        XCTAssertEqual(setup.store.status, .ready(accountId: "vault"))
        XCTAssertEqual(setup.store.error?.title, MessageCryptoError.authenticationFailed.localizedDescription)
    }

    func testALockedKeyIsReportedNotRetried() async throws {
        let setup = await setUpStore()
        setup.store.sealedText = try setup.backend.sealedMessage("hello", for: try setup.account("vault")).absoluteString
        try await settle(setup.store)

        setup.panel.lockSelectedKey()
        await setup.store.decrypt()

        XCTAssertTrue(setup.store.plaintext.isEmpty)
        XCTAssertNotNil(setup.store.error)
        XCTAssertTrue(setup.backend.deriveMessageKeyCalls.isEmpty)
    }

    // MARK: - Ending

    func testClosingWipesTextAndKeys() async throws {
        let setup = await setUpStore()
        let vault = try setup.account("vault")
        let message = try setup.backend.sealedMessage("hello", for: vault)
        setup.store.sealedText = message.absoluteString
        try await settle(setup.store)
        await setup.store.decrypt()
        XCTAssertEqual(setup.store.plaintext, "hello")

        setup.store.close()
        XCTAssertTrue(setup.store.plaintext.isEmpty)
        XCTAssertTrue(setup.store.sealedText.isEmpty)
        XCTAssertEqual(setup.store.status, .empty)

        // The keys went with it: the same message costs a touch again.
        setup.store.sealedText = message.absoluteString
        try await settle(setup.store)
        await setup.store.decrypt()
        XCTAssertEqual(setup.backend.deriveMessageKeyCalls.count, 2)
    }

    func testAMessageHandedInIsReadAsIfPasted() async throws {
        let setup = await setUpStore()
        let message = try setup.backend.sealedMessage("clicked", for: try setup.account("vault"))
        let store = MessageDecryptStore(accounts: setup.panel.accounts,
                                        touchGate: setup.panel.touchGate,
                                        devicePath: setup.device.path,
                                        deviceName: "Key",
                                        prefilled: message)
        XCTAssertEqual(store.sealedText, message.absoluteString)
        try await settle(store)
        XCTAssertEqual(store.status, .ready(accountId: "vault"))
        XCTAssertTrue(setup.backend.deriveMessageKeyCalls.isEmpty, "a link never touches the key by itself")
    }
}

@MainActor
extension MessageDecryptStoreTests {
    func testDifferentAccountsSharingNonceMustUseDifferentCachedKeys() async throws {
        let (panel, backend, device) = await AppTestFactory.unlockedStore()
        let store = MessageDecryptStore(accounts: panel.accounts, touchGate: panel.touchGate,
                                        devicePath: device.path, deviceName: "Synthetic key")
        let first = try XCTUnwrap(panel.accounts.accounts.first)
        let second = try XCTUnwrap(panel.accounts.accounts.last)
        store.adopt(try backend.sealedMessage("first sample", for: first))
        try await waitUntil { store.canDecrypt }
        await store.decrypt()
        store.adopt(try backend.sealedMessage("second sample", for: second))
        try await waitUntil { store.canDecrypt }
        await store.decrypt()
        XCTAssertTrue(store.plaintext == "second sample", "Nonce cache selected another account's key")
        store.close()
    }

    func testClosingDuringDerivationMustPreventKeyCacheResurrection() async throws {
        let (panel, backend, device) = await AppTestFactory.unlockedStore()
        let store = MessageDecryptStore(accounts: panel.accounts, touchGate: panel.touchGate,
                                        devicePath: device.path, deviceName: "Synthetic key")
        let account = try XCTUnwrap(panel.accounts.accounts.first)
        let message = try backend.sealedMessage("public sample", for: account)
        let gate = BlockingGate()
        defer { gate.open() }
        backend.deriveMessageKeyGate = gate
        store.adopt(message)
        try await waitUntil { store.canDecrypt }
        let task = Task { await store.decrypt() }
        try await waitUntil { gate.hasEntered }
        store.close()
        gate.open()
        await task.value
        // Reuse exposes whether a private key re-entered the supposedly emptied cache.
        store.adopt(message)
        try await waitUntil { store.canDecrypt }
        await store.decrypt()
        XCTAssertEqual(backend.deriveMessageKeyCalls.count, 2, "Closed store retained a late key")
        store.close()
    }
}
