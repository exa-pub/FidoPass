import Foundation
import AppKit

/// One owner for secret copies. Concealment is a convention clipboard managers may honor;
/// currentHostOnly is AppKit's supported opt-out from Universal Clipboard.
@MainActor
final class ClipboardService {
    nonisolated static let defaultClearInterval: TimeInterval = 45
    private let pasteboard: any ClipboardPasteboard
    private let now: () -> Date
    private var clearWorkItem: DispatchWorkItem?
    private var ownedChangeCount: Int?
    private var onCleared: (@Sendable () -> Void)?
    private(set) var lastWriteSucceeded = false

    init(pasteboard: any ClipboardPasteboard = NSPasteboard.general, now: @escaping () -> Date = Date.init) {
        self.pasteboard = pasteboard
        self.now = now
    }

    @discardableResult
    func copySecret(_ secret: String,
                    clearAfter: TimeInterval = defaultClearInterval,
                    onCleared: (@Sendable () -> Void)? = nil) -> Date? {
        relinquish()
        lastWriteSucceeded = false
        let item = NSPasteboardItem()
        guard item.setString(secret, forType: .string),
              item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) else { return nil }
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        guard pasteboard.writeObjects([item]) else { return nil }
        lastWriteSucceeded = true
        let count = pasteboard.changeCount
        ownedChangeCount = count
        self.onCleared = onCleared
        guard clearAfter > 0 else { return nil }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ownedChangeCount == count else { return }
                self.clearIfOwned()
            }
        }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter, execute: work)
        return now().addingTimeInterval(clearAfter)
    }

    func clearIfOwned() {
        if let count = ownedChangeCount, pasteboard.changeCount == count { _ = pasteboard.clearContents() }
        relinquish()
    }

    private func relinquish() {
        clearWorkItem?.cancel()
        clearWorkItem = nil
        ownedChangeCount = nil
        let callback = onCleared
        onCleared = nil
        callback?()
    }
}
