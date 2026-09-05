import Combine
import FidoPassAppKit
import Foundation
import Sparkle

/// `UpdateService` over Sparkle, the one place the framework is used.
///
/// Inert unless the bundle carries `SUFeedURL`, which `scripts/build_app.sh` writes only
/// into Developer ID builds: a local or ad-hoc build could never install the signed release
/// anyway, and should not offer to. Every Sparkle callback is answered without a window by
/// `HeadlessUserDriver`; the resulting `UpdateState` is all the app ever sees.
@MainActor
public final class SparkleUpdateService: NSObject, UpdateService {

    /// Developer overrides, read once per check. Used to exercise the release path against
    /// a prerelease (docs/release.md). Harmless to an attacker who can write defaults: the
    /// EdDSA and Developer ID checks do not depend on where the feed came from.
    enum DefaultsKey {
        static let feedOverride = "updates.feedOverride"
        static let channel = "updates.channel"
    }

    public private(set) var isAvailable = false
    public let currentVersion: AppVersion
    @Published public private(set) var state: UpdateState = .idle
    public var statePublisher: AnyPublisher<UpdateState, Never> { $state.eraseToAnyPublisher() }
    public var canRelaunchNow: (@MainActor () -> Bool)?

    private let flow = UpdateFlow()
    private var driver: HeadlessUserDriver?
    private var updater: SPUUpdater?
    private var pendingRelaunch: (() -> Void)?
    private let defaults: UserDefaults

    public init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.currentVersion = AppVersion(bundle: bundle)
        self.defaults = defaults
        super.init()
        flow.onChange = { [weak self] state in self?.state = state }
        let driver = HeadlessUserDriver(flow: flow)
        self.driver = driver

        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") is String else { return }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            isAvailable = true
        } catch {
            // A misconfigured bundle — no key, a bad feed. Nothing to show the user and
            // nothing worth logging: the error would name the feed.
            isAvailable = false
        }
    }

    public var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    public var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    public var lastCheck: Date? { updater?.lastUpdateCheckDate }

    public func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// The click. The flow remembers it; the check that follows finds the update again and
    /// this time answers "install".
    public func install() {
        guard let updater, flow.requestInstall() else { return }
        updater.checkForUpdates()
    }

    public func relaunchGateDidOpen() {
        guard let pendingRelaunch, canRelaunchNow?() ?? true else { return }
        self.pendingRelaunch = nil
        pendingRelaunch()
    }
}

extension SparkleUpdateService: SPUUpdaterDelegate {

    public func feedURLString(for updater: SPUUpdater) -> String? {
        defaults.string(forKey: DefaultsKey.feedOverride)
    }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        guard let channel = defaults.string(forKey: DefaultsKey.channel), !channel.isEmpty else { return [] }
        return [channel]
    }

    /// A relaunch in the middle of a key operation would abandon it. The container knows;
    /// `relaunchGateDidOpen` finishes the job once it says so.
    public func updater(_ updater: SPUUpdater,
                        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                        untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        if canRelaunchNow?() ?? true { return false }
        pendingRelaunch = installHandler
        return true
    }
}
