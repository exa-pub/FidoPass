import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassApp

/// The click budget, as code.
///
/// The HUD exists to make one operation — put the usual password on the clipboard — cost
/// two clicks or two keystrokes. That promise lives or dies on what `⏎` does in each state,
/// so it is asserted here rather than described in a document nobody runs.
final class HUDReducerTests: XCTestCase {

    private let vault = AccountRef(accountId: "vault", devicePath: "/dev/one")
    private let disk = AccountRef(accountId: "disk", devicePath: "/dev/one")

    func testUnlockedKeyWithASelectionGeneratesImmediately() {
        let snapshot = HUDSnapshot(hasDevices: true,
                                   selectedDevicePath: "/dev/one",
                                   isUnlocked: true,
                                   accountRefs: [vault, disk],
                                   selection: vault)
        XCTAssertEqual(HUDReducer.primaryAction(snapshot), .generateAndCopy(vault),
                       "the daily action must be the default one, not 'now pick an account'")
    }

    /// Choosing between one option is not a choice.
    func testSingleAccountNeedsNoSelection() {
        let snapshot = HUDSnapshot(hasDevices: true,
                                   selectedDevicePath: "/dev/one",
                                   isUnlocked: true,
                                   accountRefs: [vault],
                                   selection: nil)
        XCTAssertEqual(HUDReducer.primaryAction(snapshot), .generateAndCopy(vault))
    }

    func testLockedKeyAsksForThePin() {
        let snapshot = HUDSnapshot(hasDevices: true,
                                   selectedDevicePath: "/dev/one",
                                   isUnlocked: false,
                                   accountRefs: [],
                                   selection: vault)
        XCTAssertEqual(HUDReducer.primaryAction(snapshot), .unlock(devicePath: "/dev/one"))
    }

    func testNoKeyAsksForAKey() {
        let snapshot = HUDSnapshot(hasDevices: false,
                                   selectedDevicePath: nil,
                                   isUnlocked: false,
                                   accountRefs: [],
                                   selection: nil)
        XCTAssertEqual(HUDReducer.primaryAction(snapshot), .connectKey)
    }

    func testUnlockedKeyWithoutAccountsOffersToCreateOne() {
        let snapshot = HUDSnapshot(hasDevices: true,
                                   selectedDevicePath: "/dev/one",
                                   isUnlocked: true,
                                   accountRefs: [],
                                   selection: nil)
        XCTAssertEqual(HUDReducer.primaryAction(snapshot), .createAccount)
    }

    /// A stale selection — the account was deleted, or belongs to a key that was unplugged —
    /// must not make the primary action derive from something that no longer exists. With
    /// one account left there is nothing to choose, so it still generates.
    func testStaleSelectionFallsBackToTheOnlyAccount() {
        let snapshot = HUDSnapshot(hasDevices: true,
                                   selectedDevicePath: "/dev/one",
                                   isUnlocked: true,
                                   accountRefs: [disk],
                                   selection: vault)
        XCTAssertEqual(HUDReducer.primaryAction(snapshot), .generateAndCopy(disk))
    }

    /// With several accounts and no valid selection, deriving from an arbitrary one would be
    /// a silent mistake: every password looks equally plausible.
    func testStaleSelectionAmongSeveralAccountsAsksWhichOne() {
        let other = AccountRef(accountId: "notes", devicePath: "/dev/one")
        let snapshot = HUDSnapshot(hasDevices: true,
                                   selectedDevicePath: "/dev/one",
                                   isUnlocked: true,
                                   accountRefs: [disk, other],
                                   selection: vault)
        XCTAssertEqual(HUDReducer.primaryAction(snapshot), .chooseAccount)
    }
}

/// Preselection: what the HUD opens on, and with which label.
final class HUDSelectionResolutionTests: XCTestCase {

    private let device = MockKeyBackend.device(path: "/dev/one")
    private var accounts: [Account] {
        [Account.fixture(id: "disk", kind: .local, devicePath: "/dev/one"),
         Account.fixture(id: "vault", kind: .portable, devicePath: "/dev/one")]
    }

    func testRemembersTheAccountUsedLast() {
        let memory = Preferences.LastUsed(deviceSignature: Preferences.signature(for: device),
                                          accountId: "vault",
                                          label: "work")
        let ref = HUDReducer.resolveSelection(accounts: accounts, devices: [device], memory: memory)
        XCTAssertEqual(ref?.accountId, "vault")
    }

    /// The signature is what makes the memory survive a reconnect; a memory recorded on a
    /// different key must not select an account here.
    func testMemoryFromAnotherKeyIsIgnored() {
        let memory = Preferences.LastUsed(deviceSignature: "FFFF:FFFF", accountId: "vault", label: "work")
        let ref = HUDReducer.resolveSelection(accounts: accounts, devices: [device], memory: memory)
        XCTAssertEqual(ref?.accountId, "disk", "falls back to the first account, not to the wrong key's memory")
    }

    func testLabelComesFromTheMemoryOfThatAccount() {
        let memory = Preferences.LastUsed(deviceSignature: Preferences.signature(for: device),
                                          accountId: "vault",
                                          label: "work")
        let ref = AccountRef(accountId: "vault", devicePath: "/dev/one")
        XCTAssertEqual(HUDReducer.resolveLabel(for: ref,
                                               accounts: accounts,
                                               devices: [device],
                                               memory: memory,
                                               recent: ["other"]),
                       "work")
    }

    /// A label remembered for one account must not leak onto another: the same label means
    /// a different password for a different account, and silently reusing it would be worse
    /// than starting from the usual default.
    func testLabelDoesNotLeakBetweenAccounts() {
        let memory = Preferences.LastUsed(deviceSignature: Preferences.signature(for: device),
                                          accountId: "vault",
                                          label: "work")
        let ref = AccountRef(accountId: "disk", devicePath: "/dev/one")
        XCTAssertEqual(HUDReducer.resolveLabel(for: ref,
                                               accounts: accounts,
                                               devices: [device],
                                               memory: memory,
                                               recent: ["recent-one"]),
                       "recent-one")
    }

    func testLabelFallsBackToTheConventionalDefault() {
        XCTAssertEqual(HUDReducer.resolveLabel(for: nil,
                                               accounts: accounts,
                                               devices: [device],
                                               memory: nil,
                                               recent: []),
                       "default")
    }
}
