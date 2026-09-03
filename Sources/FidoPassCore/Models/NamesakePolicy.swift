import Foundation

/// Whether creating an account may reuse a name already on the key.
///
/// Two accounts with one name on one key are indistinguishable in the panel and occupy a
/// slot each, so creation refuses a name taken under *any* relying party FidoPass writes
/// to. Migration is the one exception: it creates the v2 copy of a v1 portable account under
/// that account's own name, and the pair "v1 and v2 with one name" is what an unfinished
/// migration looks like — it can arise no other way precisely because of the refusal.
public enum NamesakePolicy: Sendable, Hashable {
    /// The name must be free everywhere. What every caller but migration gets.
    case refuse
    /// One namesake is allowed: a v1 portable account, the one being migrated.
    case allowLegacyTwin
}
