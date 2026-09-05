import AppKit
import FidoPassAppKit
import Sparkle

/// Sparkle's user interface, without the interface.
///
/// Sparkle calls these on the main thread (the protocol is `NS_SWIFT_UI_ACTOR`) and expects
/// windows, alerts and progress bars. This driver answers every call at once and turns it
/// into an `UpdateState`; the status icon, the menu and Preferences render that. No method
/// here creates a window, an alert or a notification.
@MainActor
final class HeadlessUserDriver: NSObject, SPUUserDriver {

    private let flow: UpdateFlow

    init(flow: UpdateFlow) {
        self.flow = flow
    }

    // MARK: - Permission

    /// Only asked when `SUEnableAutomaticChecks` is missing from Info.plist, which the build
    /// script never allows. Answered from the app's defaults anyway, and never with a
    /// system profile.
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping @Sendable () -> Void) {
        flow.checkStarted()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        let stage: UpdateFlow.Stage
        switch state.stage {
        case .notDownloaded: stage = .notDownloaded
        case .downloaded: stage = .downloaded
        case .installing: stage = .installing
        @unknown default: stage = .notDownloaded
        }
        switch flow.found(Self.candidate(from: appcastItem), stage: stage) {
        case .install: reply(.install)
        case .dismiss: reply(.dismiss)
        }
    }

    static func candidate(from item: SUAppcastItem) -> UpdateCandidate {
        UpdateCandidate(version: item.displayVersionString,
                        build: item.versionString,
                        releaseNotesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL,
                        isCritical: item.isCriticalUpdate)
    }

    /// Release notes are a link in Preferences, never a web view in the app.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping @Sendable () -> Void) {
        flow.notFound()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping @Sendable () -> Void) {
        flow.failed(error.localizedDescription)
        acknowledgement()
    }

    // MARK: - Downloading and installing

    func showDownloadInitiated(cancellation: @escaping @Sendable () -> Void) {
        flow.downloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        flow.downloadExpects(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        flow.downloadReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        flow.extracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        switch flow.readyToInstall() {
        case .install: reply(.install)
        case .dismiss: reply(.dismiss)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping @Sendable () -> Void) {
        flow.installing()
    }

    /// Runs in the relaunched app. The new version is simply the version now.
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping @Sendable () -> Void) {
        acknowledgement()
    }

    /// A check requested while a session is already running. The state already says what
    /// is happening, and Preferences shows it.
    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        flow.sessionEnded()
    }
}
