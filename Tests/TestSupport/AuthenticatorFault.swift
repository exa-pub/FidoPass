import Foundation

package enum AuthenticatorFault: Sendable {
    case rejectSubcommand(command: UInt8, subcommand: UInt8, status: UInt8)
    case reject(command: UInt8, status: UInt8)
    case loseReply(command: UInt8)
    case malformed(command: UInt8, reply: Data)

    package var command: UInt8 {
        switch self {
        case .rejectSubcommand(let command, _, _), .reject(let command, _), .loseReply(let command), .malformed(let command, _): command
        }
    }
    /// libfido2 emits a canonical CBOR map: unsigned key 1 is the credman subcommand.
    package func matches(_ payload: Data) -> Bool {
        guard payload.first == command else { return false }
        if case .rejectSubcommand(_, let subcommand, _) = self {
            let bytes = Array(payload.prefix(4))
            return bytes.count == 4 && bytes[1] & 0xe0 == 0xa0 && bytes[2] == 1 && bytes[3] == subcommand
        }
        return true
    }
}
