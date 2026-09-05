import Foundation

/// Read-only compatibility for deletion markers written by the former sync adapter.
struct LabelDeletionState: Codable {
    var clearedAt: Date = .distantPast
    var scopes: [String: Date] = [:]

    func permits(id: String, usedAt: Date) -> Bool {
        usedAt > max(clearedAt, scopes[id] ?? .distantPast)
    }
}
