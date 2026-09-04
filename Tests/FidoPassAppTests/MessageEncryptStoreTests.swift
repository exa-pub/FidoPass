import Combine
import XCTest
@testable import FidoPassAppKit
import FidoPassCore
import TestSupport

/// The sending window: a link in, a message out, and nothing that needs a key.
@MainActor
final class MessageEncryptStoreTests: AppTestCase {

    private let backend = MockKeyBackend()
    private let vault = AccountHandle.fixture(id: "vault", devicePath: "/dev/one")

    private func settleKey(_ store: MessageEncryptStore) async throws {
        var finished = false
        let subscription = store.$keyStatus.dropFirst().sink {
            if $0 != .verifying { finished = true }
        }
        defer { subscription.cancel() }
        try await waitUntil { finished }
    }

    private func makeStore() -> MessageEncryptStore {
        MessageEncryptStore(sealer: backend.messages)
    }

    // MARK: - The key

    func testPastingAKeyShowsItsFingerprint() async throws {
        let store = makeStore()
        let key = try backend.encryptionKey(for: vault)
        store.keyText = key.absoluteString
        try await settleKey(store)

        XCTAssertEqual(store.keyStatus, .valid(key.fingerprint))
        XCTAssertEqual(store.key, key)
    }

    /// Half a link is the ordinary state of the field, not an error to shout about.
    func testAPrefixIsIncompleteNotWrong() async throws {
        let store = makeStore()
        let key = try backend.encryptionKey(for: vault)
        store.keyText = String(key.absoluteString.prefix(60))
        try await settleKey(store)

        XCTAssertEqual(store.keyStatus, .incomplete)
        XCTAssertNil(store.key)
    }

    /// The checksum is required, but a link cut off before it is a prefix like any other.
    func testAKeyWithoutItsChecksumIsIncomplete() async throws {
        let store = makeStore()
        store.keyText = LinkCarrier.web.prefix + (try backend.encryptionKey(for: vault).payload)
        try await settleKey(store)

        XCTAssertEqual(store.keyStatus, .incomplete)
    }

    func testAMessageInTheKeyFieldIsNamed() async throws {
        let store = makeStore()
        store.keyText = try backend.sealedMessage("hi", for: vault).absoluteString
        try await settleKey(store)

        XCTAssertEqual(store.keyStatus, .invalid(.unexpectedKind("hpkeblobv1")))
    }

    func testClearingTheKeyClearsTheMessage() async throws {
        let store = makeStore()
        store.adopt(try backend.encryptionKey(for: vault), issuedFor: nil)
        store.plaintext = "hello"
        try await waitUntil { store.status != .sealing }
        XCTAssertEqual(store.status, .sealed)

        store.keyText = ""
        XCTAssertEqual(store.keyStatus, .empty)
        XCTAssertTrue(store.sealed.isEmpty)
        XCTAssertEqual(store.status, .noKey, "the text is still there, waiting for a key")
    }

    // MARK: - The text

    func testTextWithoutAKeyWaitsForOne() async throws {
        let store = makeStore()
        store.plaintext = "hello"
        try await waitUntil { store.status != .sealing }

        XCTAssertEqual(store.status, .noKey)
        XCTAssertTrue(store.sealed.isEmpty)
    }

    func testTextUnderAKeySealsToAMessageTheKeyOpens() async throws {
        let store = makeStore()
        store.adopt(try backend.encryptionKey(for: vault), issuedFor: vault.account)
        store.plaintext = "seed phrase"
        try await waitUntil { store.status != .sealing }

        XCTAssertEqual(store.status, .sealed)
        let message = try SealedMessageURL(parsing: store.sealed)
        let key = try backend.deriveMessageKey(vault, nonce: MockKeyBackend.testNonce, pinProvider: { nil })
        XCTAssertEqual(try backend.messages.open(message, with: key), "seed phrase")
    }

    /// Every edit is a new message — a fresh ephemeral key — so the output changes; what must
    /// not happen is the store recomputing when nothing was edited.
    func testTheMessageSettlesWhenTheTextDoes() async throws {
        let store = makeStore()
        store.adopt(try backend.encryptionKey(for: vault), issuedFor: nil)
        store.plaintext = "stable"
        try await waitUntil { store.status != .sealing }
        let first = store.sealed
        XCTAssertFalse(first.isEmpty)

        try await Task.sleep(for: MessageEncryptStore.debounce + .milliseconds(50))
        XCTAssertEqual(store.sealed, first, "recomputed without an edit")
    }

    func testClearingTheTextClearsTheMessageAtOnce() async throws {
        let store = makeStore()
        store.adopt(try backend.encryptionKey(for: vault), issuedFor: nil)
        store.plaintext = "something"
        try await waitUntil { store.status != .sealing }
        XCTAssertFalse(store.sealed.isEmpty)

        store.plaintext = ""
        XCTAssertTrue(store.sealed.isEmpty, "clearing must not wait out the debounce")
        XCTAssertEqual(store.status, .empty)
    }

    func testOversizedTextIsRefusedWithTheLimit() async throws {
        let store = makeStore()
        store.adopt(try backend.encryptionKey(for: vault), issuedFor: nil)
        store.plaintext = String(repeating: "a", count: MessageLimits.maxPlaintextCharacters + 1)
        try await waitUntil { store.status != .sealing }

        XCTAssertEqual(store.status, .tooLarge(limit: MessageLimits.maxPlaintextCharacters))
        XCTAssertTrue(store.sealed.isEmpty)
    }

    // MARK: - A key handed in

    /// The panel issued a key, or a link was clicked: it goes in as it is, no debounce and no
    /// second reading, and the text that was already there is sealed under it.
    func testAdoptingAKeySealsTheTextAlreadyThere() async throws {
        let store = makeStore()
        store.plaintext = "written first"
        try await waitUntil { store.status != .sealing }
        XCTAssertEqual(store.status, .noKey)

        let key = try backend.encryptionKey(for: vault)
        store.adopt(key, issuedFor: vault.account)
        XCTAssertEqual(store.keyText, key.absoluteString)
        XCTAssertEqual(store.keyStatus, .valid(key.fingerprint))
        XCTAssertEqual(store.issuedFor, vault.account)
        try await waitUntil { store.status != .sealing }
        XCTAssertEqual(store.status, .sealed)
    }

    /// Typing over an issued key means another key: the account it was issued for no longer
    /// describes what is in the field.
    func testEditingTheKeyDropsTheIssuedAccount() async throws {
        let store = makeStore()
        store.adopt(try backend.encryptionKey(for: vault), issuedFor: vault.account)
        store.keyText = "https://fidopass.org/link#hpkev1?nonce="

        XCTAssertNil(store.issuedFor)
        XCTAssertNil(store.key)
        XCTAssertEqual(store.keyStatus, .incomplete)
    }
}

@MainActor
extension MessageEncryptStoreTests {
    private func sealedStore() async throws -> MessageEncryptStore {
        let backend = MockKeyBackend()
        let account = AccountHandle.fixture(id: "vault", devicePath: "/dev/one")
        let store = MessageEncryptStore(sealer: backend.messages,
                                       prefilled: try backend.encryptionKey(for: account))
        store.plaintext = "public synthetic sample"
        try await waitUntil { store.status == .sealed }
        return store
    }

    func testPlaintextEditMustImmediatelyInvalidateCopyableCiphertext() async throws {
        let store = try await sealedStore()
        store.plaintext = "edited public sample"
        XCTAssertTrue(store.sealed.isEmpty, "Old ciphertext remains copyable during debounce")
        store.clear()
    }

    func testRecipientEditMustImmediatelyInvalidateCopyableCiphertext() async throws {
        let store = try await sealedStore()
        store.keyText = "https://fidopass.org/link#hpkev1?nonce="
        XCTAssertTrue(store.sealed.isEmpty, "Old recipient's ciphertext remains copyable")
        store.clear()
        store.keyText = ""
    }
}
