import Foundation

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
