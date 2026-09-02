import Foundation

/// Which window a wait belongs to.
///
/// A touch prompt is drawn where the user is looking. The panel draws its own; a reset run
/// from the manager is the manager's business, and the panel must neither show it nor be
/// held open by it.
enum TouchSurface: Equatable, Sendable {
    case panel
    case manager
}
