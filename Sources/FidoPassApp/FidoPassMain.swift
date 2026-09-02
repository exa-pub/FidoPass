import AppKit
import FidoPassAppKit

/// Entry point, and nothing else.
///
/// The whole application lives in `FidoPassAppKit`; keeping this target this thin is what
/// lets the app be a library — testable, and with one place (`AppDelegate`) that assembles it.
@main
@MainActor
enum FidoPassMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
