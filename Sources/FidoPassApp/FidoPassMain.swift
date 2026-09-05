import AppKit
import FidoPassAppKit
import FidoPassUpdater

/// Entry point, and nothing else.
///
/// The whole application lives in `FidoPassAppKit`; keeping this target this thin is what
/// lets the app be a library — testable, and with one place (`AppDelegate`) that assembles it.
/// The updater is the one thing handed in from here, so that Sparkle is linked by the app
/// alone and never by the tests.
@main
@MainActor
enum FidoPassMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate(updates: SparkleUpdateService())
        application.delegate = delegate
        application.run()
    }
}
