import Combine
import Foundation

/// What Preferences and onboarding observe about updates.
///
/// The service is a protocol so the app can be built without Sparkle; SwiftUI wants an
/// `ObservableObject`. This mirrors the service's state and forwards the two switches.
@MainActor
final class UpdateModel: ObservableObject {
    @Published private(set) var state: UpdateState
    @Published var automaticallyChecks: Bool {
        didSet { if automaticallyChecks != service.automaticallyChecks { service.automaticallyChecks = automaticallyChecks } }
    }
    @Published var automaticallyDownloads: Bool {
        didSet { if automaticallyDownloads != service.automaticallyDownloads { service.automaticallyDownloads = automaticallyDownloads } }
    }
    let isAvailable: Bool
    let version: AppVersion
    /// Why the dot would never do anything from where the app runs, or nil.
    let installHint: String?

    private let service: any UpdateService
    private var subscription: AnyCancellable?

    init(service: any UpdateService, bundleURL: URL = Bundle.main.bundleURL) {
        self.service = service
        self.state = service.state
        self.automaticallyChecks = service.automaticallyChecks
        self.automaticallyDownloads = service.automaticallyDownloads
        self.isAvailable = service.isAvailable
        self.version = service.currentVersion
        self.installHint = service.isAvailable ? InstallLocation.updateHint(for: bundleURL) : nil
        // The service is main-actor bound and publishes the new value itself, so there is
        // no hop: the row in Preferences changes in the same turn as the state.
        subscription = service.statePublisher
            .sink { [weak self] state in self?.state = state }
    }

    var lastCheck: Date? { service.lastCheck }

    /// The switches live in the updater's own defaults; re-read them when a window opens.
    func reload() {
        automaticallyChecks = service.automaticallyChecks
        automaticallyDownloads = service.automaticallyDownloads
    }

    func checkNow() { service.checkForUpdates() }
    func install() { service.install() }

    /// The one line Preferences shows for the current state.
    var statusText: String {
        switch state {
        case .idle:
            if let lastCheck { return "Last checked \(Self.relative(lastCheck))" }
            return "Not checked yet"
        case .checking:
            return "Checking…"
        case .upToDate(let checkedAt):
            return "Up to date, checked \(Self.relative(checkedAt))"
        case .available(let candidate):
            return "\(candidate.version) is available"
        case .downloading(let candidate, let fraction):
            if let fraction { return "Downloading \(candidate.version)… \(Int(fraction * 100))%" }
            return "Preparing \(candidate.version)…"
        case .readyToInstall(let candidate):
            return "\(candidate.version) is downloaded and verified"
        case .installing(let candidate):
            return "Installing \(candidate.version)…"
        case .failed(let message, _):
            return message
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
