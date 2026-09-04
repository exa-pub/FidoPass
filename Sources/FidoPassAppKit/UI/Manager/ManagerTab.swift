import Foundation

enum ManagerTab: String, Hashable, CaseIterable, Identifiable {
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
