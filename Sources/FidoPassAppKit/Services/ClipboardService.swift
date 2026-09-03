import Foundation
import AppKit

/// Puts a derived secret on the pasteboard with the handling such a value deserves.
///
/// A plain `setString` leaks in three directions: the value stays on the pasteboard
/// indefinitely, clipboard managers archive it into their searchable history, and
/// Universal Clipboard forwards it to every other Apple device on the account. All three
/// are addressed here.
///
/// One instance per application: the pending wipe is state, and two of them would race to
/// clear a pasteboard only one of them wrote.
@MainActor
final class ClipboardService {

    /// Convention honoured by clipboard managers (Maccy, Alfred, Raycast and others) to
    /// mean "do not record this in history". Not an Apple API — just a widely respected
    /// agreement, and free to add.
    private static let concealedType = "org.nspasteboard.ConcealedType"

    /// How long a secret is allowed to stay on the pasteboard.
    nonisolated static let defaultClearInterval: TimeInterval = 45

    private var clearWorkItem: DispatchWorkItem?

    init() {}

    /// Copies `secret`, then clears the pasteboard after `clearAfter` seconds.
    ///
    /// - Parameter syncAcrossDevices: when false the value never leaves this Mac.
    /// - Returns: the deadline at which the pasteboard will be cleared, for UI countdowns.
    /// - Parameter onCleared: called on the main queue once the value is no longer ours to
    ///   clear — either because the timeout elapsed or because something else took over the
    ///   pasteboard. Lets the UI stop advertising a countdown that no longer applies.
    @discardableResult
    func copySecret(_ secret: String,
                    clearAfter: TimeInterval = defaultClearInterval,
                    syncAcrossDevices: Bool = false,
                    onCleared: (@Sendable () -> Void)? = nil) -> Date? {
        let pasteboard = NSPasteboard.general
        clearWorkItem?.cancel()

        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        // Marking it concealed keeps it out of clipboard-manager history.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType(Self.concealedType))
        if !syncAcrossDevices {
            // Opting out of Universal Clipboard keeps the secret on this machine.
            pasteboard.setData(Data([1]), forType: NSPasteboard.PasteboardType("com.apple.is-sensitive"))
        }

        guard clearAfter > 0 else { return nil }

        // Remember which pasteboard generation is ours: if anything else is copied in the
        // meantime, clearing would destroy the user's newer content instead of our secret.
        let ownedChangeCount = pasteboard.changeCount
        let work = DispatchWorkItem {
            if NSPasteboard.general.changeCount == ownedChangeCount {
                NSPasteboard.general.clearContents()
            }
            // Fires either way: if someone else copied over it, our secret is equally gone.
            onCleared?()
        }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter, execute: work)
        return Date().addingTimeInterval(clearAfter)
    }

    /// Clears the pasteboard immediately, but only if it still holds what we put there.
    func clearIfOwned() {
        clearWorkItem?.perform()
        clearWorkItem = nil
    }
}
