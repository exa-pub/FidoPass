import Carbon.HIToolbox
import Foundation

/// A key combination registered system-wide.
struct HotkeyCombo: Codable, Equatable, Sendable {
    /// Virtual key code (`kVK_ANSI_P` and friends).
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …).
    var modifiers: UInt32
    /// What to print in the UI. Stored rather than derived so the display never disagrees
    /// with what was actually registered.
    var display: String

    /// ⌘⌥P — "password", and unlikely to be taken by anything else.
    static let `default` = HotkeyCombo(keyCode: UInt32(kVK_ANSI_P),
                                       modifiers: UInt32(cmdKey | optionKey),
                                       display: "⌘⌥P")
}
