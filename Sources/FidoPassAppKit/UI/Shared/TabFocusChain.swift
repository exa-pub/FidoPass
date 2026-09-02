import SwiftUI

/// Makes Tab walk the fields of a HUD screen.
///
/// The panel is a borderless `NSPanel`, and AppKit builds no key-view loop for such a window:
/// the field editor has no `nextKeyView` to hand focus to, so Tab does nothing at all and the
/// second field of a two-field screen is reachable only with the mouse. Turning on
/// `autorecalculatesKeyViewLoop` did not change that, so the order is stated here instead of
/// left to be inferred.
///
/// It is deliberately per-screen rather than global. The chain a screen wants is the order its
/// own fields appear in, and the accounts screen already gives Tab-adjacent keys — the arrows —
/// a meaning of its own that a window-wide handler would fight with.
struct TabFocusChain<Field: Hashable>: ViewModifier {
    let order: [Field]
    @FocusState.Binding var focus: Field?

    func body(content: Content) -> some View {
        content.background {
            // Invisible buttons are the only way to bind a key in a panel that is not a
            // document window — the same device the panel already uses for its shortcuts.
            Group {
                Button("") { move(by: 1) }
                    .keyboardShortcut(.tab, modifiers: [])
                Button("") { move(by: -1) }
                    .keyboardShortcut(.tab, modifiers: [.shift])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// Wraps around: from the last field Tab returns to the first, which is what every other
    /// form on the system does.
    private func move(by step: Int) {
        guard !order.isEmpty else { return }
        let current = focus.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        let next = ((current + step) % order.count + order.count) % order.count
        focus = order[next]
    }
}

extension View {
    /// - Parameter order: the fields in the order Tab should visit them.
    func tabFocusChain<Field: Hashable>(_ order: [Field],
                                        focus: FocusState<Field?>.Binding) -> some View {
        modifier(TabFocusChain(order: order, focus: focus))
    }
}
