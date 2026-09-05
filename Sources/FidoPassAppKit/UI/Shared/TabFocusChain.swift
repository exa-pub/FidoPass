import SwiftUI

/// Per-screen Tab order for the borderless HUD, where AppKit supplies no key-view loop.
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
