import Foundation

struct MessageCacheKey: Hashable {
    let credentialId: String
    let nonce: Data
}
