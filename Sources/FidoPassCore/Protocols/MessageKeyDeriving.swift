import Foundation

/// Deriving an account's message key for a nonce. The one operation of message encryption
/// that talks to the authenticator.
public protocol MessageKeyDeriving: Sendable {
    /// One touch. The same account and nonce always yield the same key — on a second security
    /// key too, for a portable account, which is what makes a backup able to read the mail.
    ///
    /// Issuing a key and opening a message are the same call: the first keeps `url` and wipes
    /// the rest, the second keeps the whole thing for as long as its window is open.
    func deriveMessageKey(_ handle: AccountHandle,
                          nonce: Data,
                          pinProvider: (@Sendable () -> String?)?) throws -> MessageKey
}
