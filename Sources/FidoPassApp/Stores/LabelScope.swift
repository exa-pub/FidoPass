import Foundation

/// Identity of one account's label history: the credential it belongs to.
///
/// The credential id is exact. It names one credential on one key, does not change when the
/// key is replugged or its enabled interfaces are reconfigured, and differs between a
/// portable account and its copy on a second key — all of which the vendor/product signature
/// this used to be keyed on got wrong. That signature only describes a model and its enabled
/// interfaces: two keys of the same model share it, and toggling OTP or CCID on one key
/// changes it.
///
/// A credential id is not a secret — it goes to the relying party on every assertion — but it
/// is a stable unique identifier, and it does reach the disk and iCloud here. It buys the one
/// thing worth that: a label offered under the wrong account derives a password that is valid
/// and wrong.
struct LabelScope: Hashable, Codable, Sendable {
    let credentialId: String
}

/// A scope plus what it takes to describe it to a human.
///
/// The account id and the key's name are display-only: identity is the credential id alone.
/// They travel together because the store has no way to look them up — it never sees a
/// device — and because the settings window has to name an account whose key is in a drawer.
struct LabelTarget: Equatable {
    let scope: LabelScope
    let accountId: String
    let deviceSignature: String
    let deviceName: String?
}
