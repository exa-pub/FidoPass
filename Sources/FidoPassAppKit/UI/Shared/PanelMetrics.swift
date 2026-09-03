import SwiftUI
import AppKit

/// Metrics shared by every HUD screen.
///
/// The width is fixed on purpose: a popover that changes width as its content changes reads
/// as a defect, and 340 pt is the widest a menu-bar panel can be before it stops feeling
/// like one.
enum PanelMetrics {
    static let width: CGFloat = 340
    static let maxContentHeight: CGFloat = 420
    static let corner: CGFloat = 12
    static let padding: CGFloat = 12
    /// The strip under the content — a status, an error or the keyboard hints — is never
    /// shorter than this, whatever it shows, so swapping one for another does not change
    /// the panel's height. The status was 29 pt and the hints 25 pt, and the panel hangs from
    /// the menu bar, so every status that expired moved the bottom edge in front of the user.
    static let footerHeight: CGFloat = 30
}
