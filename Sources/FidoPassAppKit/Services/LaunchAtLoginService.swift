import Foundation
import ServiceManagement

/// Whether the app starts with the session.
///
/// Behind a protocol so the settings and onboarding screens can be built without touching
/// `SMAppService`, which refuses to register an app that is not in /Applications — which is
/// where a development build never is.
@MainActor
protocol LaunchAtLoginService: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

@MainActor
final class SMAppLaunchAtLogin: LaunchAtLoginService {

    init() {}

    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails for an app that is not in /Applications, which is normal
            // during development. Surfacing it as a crash would be worse than leaving the
            // switch where the user put it.
            NSLog("FidoPass: launch at login change failed")
        }
    }
}
