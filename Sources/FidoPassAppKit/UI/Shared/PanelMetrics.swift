import SwiftUI
import AppKit

enum PanelMetrics {
    static let width: CGFloat = 340
    static let maxContentHeight: CGFloat = 420
    static let corner: CGFloat = 12
    static let padding: CGFloat = 12
    /// A fixed footer height prevents status changes from resizing the HUD.
    static let footerHeight: CGFloat = 30
}
