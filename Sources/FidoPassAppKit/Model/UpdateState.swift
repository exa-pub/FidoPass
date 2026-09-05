import Foundation

/// A release the updater has found and verified enough to name.
public struct UpdateCandidate: Equatable, Sendable {
    /// What the user sees: the release's `CFBundleShortVersionString`.
    public let version: String
    /// What the updater compares: the release's `CFBundleVersion`.
    public let build: String
    /// The release page, opened from Preferences. Never rendered inside the app.
    public let releaseNotesURL: URL?
    public let isCritical: Bool

    public init(version: String, build: String, releaseNotesURL: URL? = nil, isCritical: Bool = false) {
        self.version = version
        self.build = build
        self.releaseNotesURL = releaseNotesURL
        self.isCritical = isCritical
    }
}

/// Where the updater is, as one value the status icon, the menu and Preferences all read.
///
/// There are no windows anywhere in this flow: an available update is a dot and a menu
/// item, progress is a row in Preferences, and an error is a sentence there. Every state
/// therefore has to be expressible as text.
public enum UpdateState: Equatable, Sendable {
    /// Nothing happening and nothing known — the state before the first check.
    case idle
    case checking
    case upToDate(checkedAt: Date)
    /// Found, not downloaded. Clicking the menu item downloads and installs it.
    case available(UpdateCandidate)
    /// `fraction` is nil while the size is unknown or the archive is being unpacked.
    case downloading(UpdateCandidate, fraction: Double?)
    /// Downloaded and verified in the background. Clicking the menu item relaunches.
    case readyToInstall(UpdateCandidate)
    case installing(UpdateCandidate)
    /// `message` is what Sparkle says, already fit for a user. Never a URL or a path.
    case failed(message: String, at: Date)

    public var candidate: UpdateCandidate? {
        switch self {
        case .available(let candidate), .readyToInstall(let candidate), .installing(let candidate),
             .downloading(let candidate, _):
            return candidate
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }

    /// The dot on the status icon and the enabled menu item.
    public var offersInstall: Bool {
        switch self {
        case .available, .readyToInstall: return true
        default: return false
        }
    }

    /// The menu item exists but cannot be clicked: something is already happening.
    public var isInstalling: Bool {
        switch self {
        case .downloading, .installing: return true
        default: return false
        }
    }

    /// The status-bar menu item's title, or nil when the menu should not mention updates.
    public var menuTitle: String? {
        switch self {
        case .available(let candidate), .readyToInstall(let candidate):
            return "• Update to \(candidate.version)…"
        case .downloading(let candidate, _), .installing(let candidate):
            return "Installing \(candidate.version)…"
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }
}
