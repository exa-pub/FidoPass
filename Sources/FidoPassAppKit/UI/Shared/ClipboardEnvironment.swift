import SwiftUI

/// Hands the application's one `ClipboardService` to views deep inside a window.
///
/// The manager's detail rows copy identifiers; threading the service through every view
/// between the window and a row would be noise, and a second instance would race the first
/// over who clears the pasteboard. Nil until a window injects it — a row that copies through
/// a nil service is a wiring mistake, and says so in a debug build.
private struct ClipboardServiceKey: EnvironmentKey {
    static let defaultValue: ClipboardService? = nil
}

extension EnvironmentValues {
    var clipboard: ClipboardService? {
        get { self[ClipboardServiceKey.self] }
        set { self[ClipboardServiceKey.self] = newValue }
    }
}
