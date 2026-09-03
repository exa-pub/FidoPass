import AppKit

/// The menu-bar icon.
///
/// Template images only: the system tints them for light and dark menu bars, and anything
/// hand-coloured would look foreign in half the setups. The two states worth showing are the
/// ones the user would otherwise have to go and check — the key is locked, and a secret is
/// still on the clipboard.
enum StatusItemIcon {

    enum State: Equatable {
        case noKey
        case locked
        case unlocked
        case waitingForTouch
        case clipboardHot
    }

    static func image(for state: State) -> NSImage? {
        let name: String
        switch state {
        case .noKey:           name = "key.slash"
        case .locked:          name = "key.slash.fill"
        case .unlocked:        name = "key.fill"
        case .waitingForTouch: name = "key.radiowaves.forward.fill"
        case .clipboardHot:    name = "key.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description(for: state))
        image?.isTemplate = true
        return image
    }

    static func description(for state: State) -> String {
        switch state {
        case .noKey:           return "FidoPass — no security key connected"
        case .locked:          return "FidoPass — key locked, PIN required"
        case .unlocked:        return "FidoPass — key unlocked"
        case .waitingForTouch: return "FidoPass — waiting for you to touch the key"
        case .clipboardHot:    return "FidoPass — a secret is on the clipboard"
        }
    }

    /// A dot next to the icon while a secret is still on the clipboard.
    static func badgeVisible(for state: State) -> Bool {
        state == .clipboardHot
    }
}
