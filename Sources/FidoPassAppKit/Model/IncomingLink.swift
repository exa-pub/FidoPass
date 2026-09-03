import Foundation
import FidoPassCore

/// A `fidopass://` link handed to the app by the system — clicked in a browser, a chat, a
/// mail — sorted into what it is. The `https://fidopass.org/link#…` form is what the app
/// writes and what people paste; the system delivers only the custom scheme, which is what
/// the link page on that domain will redirect to.
///
/// Untrusted input: any web page can put such a link in front of the user. It goes through
/// exactly the strict readers a pasted link goes through, and the outcome only ever opens a
/// window with text in it. Nothing here, and nothing downstream of it, touches the key.
enum IncomingLink: Equatable {
    case encryptionKey(EncryptionKeyURL)
    case sealedMessage(SealedMessageURL)
    case unrecognised(MessageCryptoError)

    /// Reads the link. Off the main actor: a key link costs an argon2id to verify.
    static func classify(_ text: String, sealer: MessageSealing) async -> IncomingLink {
        await Task.detached {
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
        }.value
    }
}
