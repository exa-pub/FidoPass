import XCTest
import SwiftUI
@testable import FidoPassAppKit

/// The strip under the panel's content shows a status for four seconds, then the keyboard
/// hints again. The panel hangs from the menu bar, so any difference in height between the
/// two moves its bottom edge in front of the user, right after they copied a password.
final class PanelFooterTests: XCTestCase {

    @MainActor
    private func height<V: View>(of view: V) -> CGFloat {
        NSHostingView(rootView: view.frame(width: PanelMetrics.width)).fittingSize.height
    }

    @MainActor
    func testStatusHintsAndErrorStripsShareOneHeight() {
        let status = height(of: PanelFooterView(status: "Password copied — the clipboard clears itself", error: nil))
        let error = height(of: PanelFooterView(status: nil,
                                               error: PresentedError(kind: .noDevices, title: "No security key connected",
                                                                     recovery: nil, details: nil)))
        let hints = height(of: PanelHintsView(hints: ["⏎ copy", "⌘⏎ show", "↑↓ account", "⌘N new"]))
        let noHints = height(of: PanelHintsView(hints: []))

        XCTAssertEqual(status, PanelMetrics.footerHeight)
        XCTAssertEqual(error, PanelMetrics.footerHeight)
        XCTAssertEqual(hints, PanelMetrics.footerHeight)
        XCTAssertEqual(noHints, PanelMetrics.footerHeight,
                       "a screen without hints still reserves the strip, or a status there would grow the panel")
    }

    /// A message that wraps may make the strip taller — that beats truncating it — but it
    /// must never be shorter than the hints it replaces.
    @MainActor
    func testWrappedMessagesOnlyGrowTheStrip() {
        let longStatus = height(of: PanelFooterView(status: "Backup key copied — store it offline, not in a password manager",
                                                    error: nil))
        let wrongPIN = height(of: PanelFooterView(status: nil,
                                                  error: PresentedError(kind: .pinInvalid, title: "Wrong PIN",
                                                                        recovery: nil, details: nil),
                                                  retriesRemaining: 5))
        XCTAssertGreaterThanOrEqual(longStatus, PanelMetrics.footerHeight)
        XCTAssertGreaterThanOrEqual(wrongPIN, PanelMetrics.footerHeight)
    }
}
