import Foundation

public protocol SecretDeriving: Sendable {
    /// The account's secret for `label`: one `hmac-secret` assertion, which needs a touch.
    func deriveSecret(_ handle: AccountHandle,
                      label: String,
                      revision: Int,
                      pinProvider: (@Sendable () -> String?)?) throws -> Data

    /// The component a portable account's key material is XOR-ed with. One touch.
    func deriveFixedComponent(_ handle: AccountHandle,
                              pinProvider: (@Sendable () -> String?)?) throws -> Data

    /// The account's secret for a message nonce: one `hmac-secret` assertion under a salt of
    /// its own domain, which needs a touch. The 32 bytes the key answers with, as they are.
    func deriveMessageSecret(_ handle: AccountHandle,
                             nonce: Data,
                             pinProvider: (@Sendable () -> String?)?) throws -> Data
}
