import Foundation

/// The pipe session serializes requests and publishes events independently of a blocked caller.
package final class OpenSKHostClient: Sendable {
    package enum Operation: UInt8, Sendable {
        case initialize = 0, ctap = 1, powerCycle = 2, advanceClock = 3
        case configurePresence = 4, prepareLegacy = 5, hid = 6, hang = 7
        case grantTouch = 9, disconnect = 10
        case waitingForTouch = 0x80, touchFinished = 0x81
    }

    package enum Profile: UInt8, CaseIterable, Sendable {
        case standard = 0, enterprise = 1, twoSlots = 2, smallBlob = 3

        package var title: String {
            switch self {
            case .standard: "Standard"
            case .enterprise: "Enterprise"
            case .twoSlots: "Two slots"
            case .smallBlob: "Small blob"
            }
        }
    }

    package enum Presence: UInt8, Sendable {
        case immediate = 0, timeout = 1, declined = 2, controlled = 3
    }

    package struct Touch: Equatable, Sendable {
        package let requestID: UInt64
        package let id: UInt64
    }

    package struct State: Sendable {
        package let touch: Touch?
        package let touchCount: Int
        package let failure: VirtualKeyError?
    }

    private let session: OpenSKPipeSession

    package init(executable: URL, seed: Data, profile: Profile = .standard,
                 presence: Presence = .immediate, realtime: Bool = false,
                 touchTimeoutMilliseconds: UInt32 = 5_000) throws {
        guard seed.count == 32, (1...30_000).contains(touchTimeoutMilliseconds) else {
            throw VirtualKeyError.protocolViolation
        }
        session = try OpenSKPipeSession(executable: executable)
        do {
            var payload = seed + Data([profile.rawValue, presence.rawValue, realtime ? 1 : 0])
            payload.append(contentsOf: withUnsafeBytes(of: touchTimeoutMilliseconds.bigEndian, Array.init))
            try begin(operation: .initialize, payload: payload)
            _ = try finish(timeoutMilliseconds: 5_000)
        } catch {
            session.stop()
            throw error
        }
    }

    deinit { session.stop() }

    package var state: State { session.state }
    package var touchCount: Int { state.touchCount }

    package func observe(_ callback: (@Sendable () -> Void)?) { session.observe(callback) }

    package func begin(operation: Operation = .ctap, payload: Data) throws {
        try session.begin(operation: operation, payload: payload)
    }

    package func finish(timeoutMilliseconds: Int) throws -> Data {
        try session.finish(timeoutMilliseconds: timeoutMilliseconds)
    }

    package func waitForTouch(after count: Int = 0, timeout: TimeInterval = 3) -> Bool {
        session.waitForTouch(after: count, timeout: timeout)
    }

    package func grantTouch(_ touch: Touch) throws {
        try session.control(operation: .grantTouch, requestID: touch.requestID,
                            payload: Data(withUnsafeBytes(of: touch.id.bigEndian, Array.init)))
    }

    package func grantTouch() throws {
        guard let touch = state.touch else { return }
        try grantTouch(touch)
    }

    /// Stops presence even if the engine has not reached its first presence check yet.
    package func disconnect() throws {
        try session.control(operation: .disconnect, requestID: 0, payload: Data())
    }

    package func configurePresence(_ mode: Presence) throws {
        try begin(operation: .configurePresence, payload: Data([mode.rawValue]))
        _ = try finish(timeoutMilliseconds: 5_000)
    }

    package func prepareLegacy(portable: Bool, displayPayload: Bool = false) throws {
        try begin(operation: .prepareLegacy, payload: Data([displayPayload ? 2 : portable ? 1 : 0]))
        _ = try finish(timeoutMilliseconds: 5_000)
    }

    package func powerCycle() throws {
        try begin(operation: .powerCycle, payload: Data())
        _ = try finish(timeoutMilliseconds: 1_000)
    }

    package func advanceClock(milliseconds: UInt64) throws {
        try begin(operation: .advanceClock, payload: Data(withUnsafeBytes(of: milliseconds.bigEndian, Array.init)))
        _ = try finish(timeoutMilliseconds: 5_000)
    }

    package func stop() { session.stop() }
}
