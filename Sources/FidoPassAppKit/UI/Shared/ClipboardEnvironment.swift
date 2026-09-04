import SwiftUI

/// Injects the shared ClipboardService. Separate instances would race over clipboard cleanup.
private struct ClipboardServiceKey: EnvironmentKey {
    static let defaultValue: ClipboardService? = nil
}

extension EnvironmentValues {
    var clipboard: ClipboardService? {
        get { self[ClipboardServiceKey.self] }
        set { self[ClipboardServiceKey.self] = newValue }
    }
}
