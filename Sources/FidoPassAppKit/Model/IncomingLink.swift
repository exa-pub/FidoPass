import Foundation
import FidoPassCore

/// Classifies untrusted incoming links with the same readers used for pasted text.
/// The result may prefill a window; it must never trigger hardware access.
enum IncomingLink: Equatable, Sendable {
    case encryptionKey(EncryptionKeyURL)
    case sealedMessage(SealedMessageURL)
    case unrecognised(MessageCryptoError)

    /// Reads the link. Off the main actor: a key link costs an argon2id to verify.
    static func classify(_ text: String, sealer: MessageSealing) async -> IncomingLink {
        (try? await MessageCryptoWorker.shared.run { () -> IncomingLink in
            do {
                return .encryptionKey(try sealer.parseKey(text))
            } catch MessageCryptoError.unexpectedKind(let host) where host == SealedMessageURL.host {
                do {
                    return .sealedMessage(try SealedMessageURL(parsing: text))
                } catch let known as MessageCryptoError {
                    return .unrecognised(known)
                } catch {
                    return .unrecognised(.notFidoPassURL)
                }
            } catch let known as MessageCryptoError {
                return .unrecognised(known)
            } catch {
                return .unrecognised(.notFidoPassURL)
            }
        }) ?? .unrecognised(.notFidoPassURL)
    }
}
