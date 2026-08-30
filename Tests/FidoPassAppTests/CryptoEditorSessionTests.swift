import XCTest
@testable import FidoPassApp
import FidoPassCore
import TestSupport

/// Two fields bound to each other are the natural shape for this feature and also its main
/// hazard: writing a computed result into one pane is indistinguishable from the user typing
/// there, so a naive binding recomputes forever.
@MainActor
final class CryptoEditorSessionTests: XCTestCase {

    private func makeSession(label: String = "notes",
                             kind: AccountKind = .portable) throws -> CryptoEditorSession {
        let derivation = MockSecretDerivationService()
        derivation.deriveSecretClosure = { _, label, _, _ in Data(repeating: UInt8(label.count), count: 32) }
        let core = FidoPassCore(deviceLister: MockDeviceLister(),
                                enrollmentService: MockEnrollmentService(),
                                portableEnrollmentService: MockPortableEnrollmentService(),
                                secretDerivationService: derivation)
        let account = Account.fixture(id: "vault", kind: kind)
        let key = try core.deriveEncryptionKey(account: account, label: label, requireUV: true, pinProvider: nil)
        return CryptoEditorSession(account: account, label: label, key: key, core: core)
    }

    /// Waits past the debounce so the session has recomputed.
    private func settle() async throws {
        try await Task.sleep(for: CryptoEditorSession.debounce + .milliseconds(250))
    }

    func testTypingPlainTextProducesCiphertext() async throws {
        let session = try makeSession()
        session.plaintext = "seed phrase"
        try await settle()

        XCTAssertEqual(session.status, .sealed)
        XCTAssertFalse(session.ciphertext.isEmpty)
        XCTAssertTrue(session.ciphertext.hasPrefix("RlBFM"), "should be a FidoPass envelope")
    }

    func testPastingCiphertextRecoversPlainText() async throws {
        let session = try makeSession()
        session.plaintext = "seed phrase"
        try await settle()
        let sealed = session.ciphertext

        session.clear()
        session.ciphertext = sealed
        try await settle()

        XCTAssertEqual(session.status, .decrypted)
        XCTAssertEqual(session.plaintext, "seed phrase")
    }

    /// The loop guard: after the panes agree, nothing may keep rewriting them.
    func testPanesSettleInsteadOfChasingEachOther() async throws {
        let session = try makeSession()
        session.plaintext = "stable"
        try await settle()

        let ciphertextAfterFirstPass = session.ciphertext
        try await settle()
        try await settle()

        XCTAssertEqual(session.ciphertext, ciphertextAfterFirstPass,
                       "the ciphertext kept being recomputed — the panes are feeding each other")
        XCTAssertEqual(session.plaintext, "stable")
    }

    func testClearingOneSideClearsTheOtherImmediately() async throws {
        let session = try makeSession()
        session.plaintext = "something"
        try await settle()
        XCTAssertFalse(session.ciphertext.isEmpty)

        session.plaintext = ""
        XCTAssertTrue(session.ciphertext.isEmpty, "clearing must not wait out the debounce")
        XCTAssertEqual(session.status, .empty)
    }

    /// Half-typed base64 is the ordinary state of the field, not an error to shout about.
    func testIncompleteInputIsNotTreatedAsFailure() async throws {
        let session = try makeSession()
        session.ciphertext = "not base64 !!"
        try await settle()
        XCTAssertEqual(session.status, .incomplete)
    }

    func testForeignValueIsNamedAsSuch() async throws {
        let session = try makeSession()
        session.ciphertext = Data(repeating: 0xAB, count: 64).base64EncodedString()
        try await settle()
        XCTAssertEqual(session.status, .foreignFormat)
    }

    /// A value from a different label must fail rather than decrypt into noise, and the
    /// plaintext already on screen must survive the attempt.
    func testValueFromAnotherLabelIsRejectedWithoutLosingWork() async throws {
        let source = try makeSession(label: "notes")
        source.plaintext = "under notes"
        try await settle()
        let foreign = source.ciphertext

        let other = try makeSession(label: "different")
        other.plaintext = "work in progress"
        try await settle()

        other.ciphertext = foreign
        try await settle()

        XCTAssertEqual(other.status, .unreadable)
        XCTAssertEqual(other.plaintext, "work in progress", "a failed decrypt must not wipe the left pane")
    }

    func testClosingWipesBothPanesAndTheKey() async throws {
        let session = try makeSession()
        session.plaintext = "secret"
        try await settle()

        session.close()
        XCTAssertTrue(session.plaintext.isEmpty)
        XCTAssertTrue(session.ciphertext.isEmpty)

        session.plaintext = "after close"
        try await settle()
        XCTAssertEqual(session.status, .keyExpired, "the key must be gone once the window closes")
    }

    func testLocalAccountIsFlaggedAsNotBackedUp() throws {
        XCTAssertFalse(try makeSession(kind: .local).isPortable)
        XCTAssertTrue(try makeSession(kind: .portable).isPortable)
    }
}

/// The editor keeps a derived key and the plaintext in memory for as long as its window is
/// open. Every path that revokes access to an account has to take that session with it —
/// otherwise "locked" describes the account list while the secrets stay reachable in
/// another window.
@MainActor
final class CryptoEditorLockingTests: XCTestCase {

    private func makeViewModel() -> AccountsViewModel {
        let derivation = MockSecretDerivationService()
        derivation.deriveSecretClosure = { _, _, _, _ in Data(repeating: 0x11, count: 32) }
        let core = FidoPassCore(deviceLister: MockDeviceLister(),
                                enrollmentService: MockEnrollmentService(),
                                portableEnrollmentService: MockPortableEnrollmentService(),
                                secretDerivationService: derivation)
        return AccountsViewModel(core: core, enableDeviceMonitors: false)
    }

    private func attachSession(to vm: AccountsViewModel, devicePath: String) throws -> Account {
        let account = Account.fixture(id: "vault", kind: .portable, devicePath: devicePath)
        vm.selected = account
        let key = try vm.core.deriveEncryptionKey(account: account, label: "notes", requireUV: true, pinProvider: nil)
        vm.cryptoEditor = CryptoEditorSession(account: account, label: "notes", key: key, core: vm.core)
        return account
    }

    func testLockingTheDeviceClosesTheEditor() throws {
        let vm = makeViewModel()
        let device = FidoDevice(path: "/dev/one", product: "Key", manufacturer: "Vendor", vendorId: 1, productId: 2)
        _ = try attachSession(to: vm, devicePath: device.path)
        XCTAssertNotNil(vm.cryptoEditor)

        vm.lockDevice(device)
        XCTAssertNil(vm.cryptoEditor, "locking the device must not leave a live key in an open window")
    }

    /// Fires when the macOS session locks — the user has walked away from the machine.
    func testLockingEverythingClosesTheEditor() throws {
        let vm = makeViewModel()
        _ = try attachSession(to: vm, devicePath: "/dev/one")

        vm.lockAllDevices(reason: "screen locked")
        XCTAssertNil(vm.cryptoEditor)
    }

    /// Locking a different key must not disturb an unrelated session.
    func testLockingAnotherDeviceLeavesTheEditorAlone() throws {
        let vm = makeViewModel()
        _ = try attachSession(to: vm, devicePath: "/dev/one")

        let other = FidoDevice(path: "/dev/two", product: "Key", manufacturer: "Vendor", vendorId: 1, productId: 2)
        vm.lockDevice(other)
        XCTAssertNotNil(vm.cryptoEditor)
    }
}
