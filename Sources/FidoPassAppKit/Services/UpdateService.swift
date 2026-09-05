import Combine
import Foundation

/// The in-app updater, seen from the application.
///
/// The one implementation that does anything lives in `FidoPassUpdater`, the only module
/// that imports Sparkle. Everything here is plain state: the service never shows a window,
/// never touches a key, and never logs where it downloads from.
@MainActor
public protocol UpdateService: AnyObject {
    /// False in local builds, which carry no feed URL, and whenever the updater failed to
    /// start. The UI then shows the version and nothing else.
    var isAvailable: Bool { get }
    var currentVersion: AppVersion { get }
    var state: UpdateState { get }
    var statePublisher: AnyPublisher<UpdateState, Never> { get }
    /// One GET of the appcast a day. Persisted by the updater itself.
    var automaticallyChecks: Bool { get set }
    /// Download and verify in the background, so the click only relaunches. Off by default:
    /// in this mode an update is also installed when the app quits, without a click.
    var automaticallyDownloads: Bool { get set }
    var lastCheck: Date? { get }
    /// Whether the app may be relaunched right now. Owned by `AppContainer`, which knows
    /// whether a key operation is in flight.
    var canRelaunchNow: (@MainActor () -> Bool)? { get set }

    /// A user-initiated check. The result lands in `state`; nothing pops up.
    func checkForUpdates()
    /// The click on the menu item or the button: download if needed, install, relaunch.
    func install()
    /// Called when `canRelaunchNow` may have turned true again.
    func relaunchGateDidOpen()
}

/// The updater of a build that cannot update: local, virtual-keys or unsigned.
@MainActor
public final class UnavailableUpdateService: UpdateService {
    public let isAvailable = false
    public let currentVersion: AppVersion
    public let state: UpdateState = .idle
    public var statePublisher: AnyPublisher<UpdateState, Never> { Just(.idle).eraseToAnyPublisher() }
    public var automaticallyChecks = false
    public var automaticallyDownloads = false
    public let lastCheck: Date? = nil
    public var canRelaunchNow: (@MainActor () -> Bool)?

    public init(currentVersion: AppVersion = .current) {
        self.currentVersion = currentVersion
    }

    public func checkForUpdates() {}
    public func install() {}
    public func relaunchGateDidOpen() {}
}
