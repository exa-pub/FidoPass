import Foundation

/// Where the bundle runs from decides whether it can be replaced.
///
/// Sparkle refuses, silently, to update an app running from a disk image or from the
/// App Translocation cache macOS uses for a quarantined app that was never moved. The
/// user would see a dot that never does anything, so Preferences says why instead.
enum InstallLocation {
    static func updateHint(for bundleURL: URL) -> String? {
        let path = bundleURL.standardizedFileURL.path
        if path.hasPrefix("/Volumes/") {
            return "FidoPass is running from a disk image. Drag it to Applications to receive updates."
        }
        if path.contains("/AppTranslocation/") {
            return "FidoPass is running from where it was downloaded. Move it to Applications and open it from there to receive updates."
        }
        return nil
    }
}
