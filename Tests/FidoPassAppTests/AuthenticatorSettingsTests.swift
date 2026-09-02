import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassApp

/// The four settings a key lets you change about itself, and the rules around them.
///
/// Two of them cannot be undone, so the important assertions here are about what does *not*
/// happen: nothing is attempted on a locked key, and nothing is offered for a subcommand the
/// key never advertised — a control that can only fail is worse than no control.
@MainActor
final class AuthenticatorSettingsTests: XCTestCase {

    private func makeStore() -> (HUDStore, MockKeyBackend, FidoDevice) {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        return (HUDTestFactory.makeStore(backend: backend), backend, device)
    }

    /// Every one of these needs the PIN, and the store holds it only while unlocked. A locked
    /// key must fail before it reaches the backend rather than sending a PIN it does not have.
    func testNothingIsAttemptedOnALockedKey() async {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()

        let operations: [() async throws -> Void] = [
            { _ = try await store.devices.toggleAlwaysUV(for: device) },
            { try await store.devices.setMinimumPINLength(for: device, length: 6) },
            { try await store.devices.forcePINChange(for: device) },
            { try await store.devices.enableEnterpriseAttestation(for: device) },
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("a locked key must refuse before the backend is reached")
            } catch {
                XCTAssertTrue(error is DeviceStoreError)
            }
        }
        XCTAssertTrue(backend.configCalls.isEmpty, "nothing may reach the key")
    }

    /// `alwaysUv` is a toggle: the request carries no value, so the result is whatever the key
    /// reports afterwards. The store returns that rather than what the caller assumed.
    func testAlwaysUVReportsTheStateTheKeyEndsIn() async throws {
        let (store, backend, device) = makeStore()
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")

        let first = try await store.devices.toggleAlwaysUV(for: device)
        XCTAssertTrue(first)
        let second = try await store.devices.toggleAlwaysUV(for: device)
        XCTAssertFalse(second, "toggling twice must come back to where it started")
        XCTAssertEqual(backend.configCalls, ["toggleAlwaysUV", "toggleAlwaysUV"])
    }

    /// Forcing a PIN change makes the key refuse everything else, and the HUD routes on that
    /// flag — so the store has to re-read it rather than leave the app describing a key that
    /// no longer behaves that way.
    func testForcingAPINChangeRefreshesTheRoutingFlag() async throws {
        let (store, backend, device) = makeStore()
        backend.statusByPath[device.path] = DeviceStatus(pinRetriesRemaining: 8,
                                                         hasPIN: true,
                                                         supportsHmacSecret: true,
                                                         remainingResidentKeys: 90,
                                                         minPINLength: 4,
                                                         forcePINChange: true)
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")

        try await store.devices.forcePINChange(for: device)

        XCTAssertEqual(store.devices.state(for: device.path)?.forcePINChange, true)
        XCTAssertEqual(store.effectiveRoute, .pinChangeRequired, "the key now refuses everything else")
    }

    /// Raising the minimum can make the key demand a new PIN, which is the same flag again.
    func testRaisingTheMinimumRefreshesTheKeyState() async throws {
        let (store, backend, device) = makeStore()
        backend.statusByPath[device.path] = DeviceStatus(pinRetriesRemaining: 8,
                                                         hasPIN: true,
                                                         supportsHmacSecret: true,
                                                         remainingResidentKeys: 90,
                                                         minPINLength: 8,
                                                         forcePINChange: false)
        await store.devices.refresh()
        try await store.devices.unlock(device, pin: "1234")

        try await store.devices.setMinimumPINLength(for: device, length: 8)

        XCTAssertEqual(backend.configCalls, ["setMinimumPINLength(8)"])
        XCTAssertEqual(store.devices.state(for: device.path)?.minPINLength, 8)
        XCTAssertEqual(store.devices.state(for: device.path)?.pinPolicy.minLengthBytes, 8,
                       "the PIN field must enforce what the key now demands")
    }

    // MARK: - Capability gating

    /// An option the key never mentioned means "not implemented"; `false` means "implemented
    /// and off". Offering a switch for the first produces a control that can only fail.
    func testCapabilitiesFollowWhatTheKeyAdvertises() {
        let full = MockKeyBackend.info()
        XCTAssertTrue(full.supportsConfiguration)
        XCTAssertTrue(full.canToggleAlwaysUV, "advertised as false, which still means settable")
        XCTAssertFalse(full.alwaysUV)
        XCTAssertTrue(full.canSetMinimumPINLength)
        XCTAssertFalse(full.canEnableEnterpriseAttestation, "never mentioned — not implemented")
        XCTAssertTrue(full.hasConfigurableSettings)

        let bare = MockKeyBackend.info(options: [.init(name: "clientPin", value: true)])
        XCTAssertFalse(bare.supportsConfiguration)
        XCTAssertFalse(bare.canToggleAlwaysUV)
        XCTAssertFalse(bare.canSetMinimumPINLength)
        XCTAssertFalse(bare.canForcePINChange)
        XCTAssertFalse(bare.hasConfigurableSettings, "the whole section should be hidden")
    }

    func testOptionDistinguishesAbsentFromFalse() {
        let info = MockKeyBackend.info(options: [.init(name: "alwaysUv", value: false)])
        XCTAssertEqual(info.option("alwaysUv"), false)
        XCTAssertNil(info.option("ep"), "absent must not read as false")
    }

    /// A key with `authnrCfg` but no PIN yet has nothing to force a change of.
    func testForcePINChangeNeedsAPINToBeginWith() {
        let info = MockKeyBackend.info(options: [.init(name: "authnrCfg", value: true)])
        XCTAssertTrue(info.canForcePINChange, "the fixture key has a PIN")

        let noPIN = AuthenticatorInfo(isFIDO2: true, ctapHIDProtocol: 2, ctapHIDVersion: "5.7.4",
                                      capabilities: [], supportsPIN: true, supportsUV: false,
                                      supportsCredentialManagement: true, supportsCredentialProtection: true,
                                      supportsPermissions: true, hasPIN: false, hasUV: false,
                                      pinRetriesRemaining: nil, uvRetriesRemaining: nil,
                                      versions: [], extensions: [],
                                      options: [.init(name: "authnrCfg", value: true)],
                                      aaguid: nil, pinProtocols: [], algorithms: [], transports: [],
                                      certifications: [], firmwareVersion: 0,
                                      limits: MockKeyBackend.info().limits, minPINLength: nil,
                                      forcePINChange: false, remainingResidentKeys: nil,
                                      uvAttempts: nil, uvModalities: [])
        XCTAssertFalse(noPIN.canForcePINChange)
    }
}
