import Foundation

/// Ordinary creation requires a unique name across FidoPass relying parties.
/// Only migration permits a portable v1 account’s namesake v2 copy.
public enum NamesakePolicy: Sendable, Hashable {
    /// The name must be free everywhere. What every caller but migration gets.
    case refuse
    /// One namesake is allowed: a v1 portable account, the one being migrated.
    case allowLegacyTwin
}
