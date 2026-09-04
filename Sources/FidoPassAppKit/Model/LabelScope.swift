import Foundation

/// Persistent label-history scope. Copies on different keys have different credential IDs.
/// Model signatures cannot identify an individual key.
struct LabelScope: Hashable, Codable, Sendable {
    let credentialId: String
}
