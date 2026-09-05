import FidoPassAppKit
import Foundation

/// The state machine behind the headless user driver.
///
/// Sparkle drives its user interface through a series of callbacks that expect an answer:
/// "an update was found, install or dismiss?", "ready to relaunch, now?". This object gives
/// every one of those an immediate answer and keeps the user's decision itself — the click
/// on the menu item — in one flag. Nothing here knows about Sparkle types, so the whole flow
/// can be tested with plain values.
///
/// The one non-obvious choice: an update Sparkle finds on its own is *dismissed*, not held
/// open until the user clicks. Holding the reply would keep a Sparkle session alive for
/// days and stop the daily check from ever seeing a newer release. Dismissing ends the
/// session at once; the click then asks Sparkle to check again, and this time the answer
/// is "install".
@MainActor
final class UpdateFlow {

    enum Choice: Equatable {
        case install
        case dismiss
    }

    /// Where Sparkle already is with an update it reports — mirrors `SPUUserUpdateStage`.
    enum Stage: Equatable {
        case notDownloaded
        case downloaded
        case installing
    }

    private(set) var state: UpdateState = .idle {
        didSet { if state != oldValue { onChange?(state) } }
    }
    var onChange: ((UpdateState) -> Void)?
    var now: () -> Date = Date.init

    /// Set by the click, cleared once Sparkle is installing or has given up.
    private(set) var installRequested = false
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    // MARK: - The user

    /// The click on "Update to …". Returns true when the caller should start a check to
    /// carry it out; false when there is nothing offered right now.
    func requestInstall() -> Bool {
        guard state.offersInstall, let candidate = state.candidate else { return false }
        installRequested = true
        state = .downloading(candidate, fraction: nil)
        return true
    }

    // MARK: - Sparkle

    func checkStarted() {
        // During an install the row already says "Installing"; a flash of "checking" would
        // only be noise.
        if !installRequested { state = .checking }
    }

    func found(_ candidate: UpdateCandidate, stage: Stage) -> Choice {
        if installRequested {
            state = stage == .notDownloaded ? .downloading(candidate, fraction: nil) : .installing(candidate)
            return .install
        }
        state = stage == .notDownloaded ? .available(candidate) : .readyToInstall(candidate)
        return .dismiss
    }

    func notFound() {
        if installRequested {
            // The dot pointed at a release that has since been pulled.
            installRequested = false
            state = .failed(message: "The update is no longer available. Check again later.", at: now())
        } else {
            state = .upToDate(checkedAt: now())
        }
    }

    func failed(_ message: String) {
        installRequested = false
        state = .failed(message: message, at: now())
    }

    func downloadStarted() {
        expectedLength = 0
        receivedLength = 0
        if let candidate = state.candidate { state = .downloading(candidate, fraction: 0) }
    }

    func downloadExpects(_ length: UInt64) {
        expectedLength = length
    }

    func downloadReceived(_ length: UInt64) {
        receivedLength += length
        guard let candidate = state.candidate else { return }
        let fraction = expectedLength > 0 ? min(1, Double(receivedLength) / Double(expectedLength)) : nil
        state = .downloading(candidate, fraction: fraction)
    }

    func extracting() {
        if let candidate = state.candidate { state = .installing(candidate) }
    }

    /// Consent was the click; there is nothing left to ask.
    func readyToInstall() -> Choice {
        if let candidate = state.candidate { state = .installing(candidate) }
        return .install
    }

    func installing() {
        installRequested = false
        if let candidate = state.candidate { state = .installing(candidate) }
    }

    /// Sparkle's session ended: after a dismissed find, after an error, after an abort. An
    /// update that was being installed and is not any more goes back to being offered.
    func sessionEnded() {
        switch state {
        case .checking:
            state = .idle
        case .downloading(let candidate, _), .installing(let candidate):
            installRequested = false
            state = .available(candidate)
        case .idle, .upToDate, .available, .readyToInstall, .failed:
            break
        }
    }
}
