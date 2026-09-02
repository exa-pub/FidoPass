import Foundation

/// The manager window's three sections.
///
/// Deliberately three and not eight. The earlier split — a sidebar row per `getInfo` field
/// group — made the reader navigate to find out what a key is, when what they wanted was to
/// read it. Everything the authenticator says about itself now lives on one page.
enum ManagerTab: String, Hashable, CaseIterable, Identifiable {
    /// First, and the window's landing page: what is *on* the key is what a person opens this
    /// window to see. What the key is comes second.
    case credentials
    case overview
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .credentials: return "Credentials"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "info.circle"
        case .credentials: return "person.text.rectangle"
        case .settings: return "gearshape"
        }
    }
}
