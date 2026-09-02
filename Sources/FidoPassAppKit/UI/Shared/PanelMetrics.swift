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
}
