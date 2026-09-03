import Foundation

/// A portable account's master key: the fixed component the key derives, XOR-ed with the
/// mask stored on the key — in `user.name` for v1, in the account's record for v2. One
/// touch to recover, and the same arithmetic in both formats, which is what lets a
/// migrated account keep its passwords.
///
/// The XOR used to be written out in three places — enrolment, export and password
/// derivation — and now message keys need it too. One function, so that "the master key" is
/// one thing.
enum PortableMasterKey {

    /// Recovers the master key. One touch, for the fixed component.
    static func recover(_ handle: AccountHandle,
                        using derivation: SecretDeriving,
                        pinProvider: (@Sendable () -> String?)?) throws -> Data {
        guard handle.account.kind == .portable else {
            throw FidoPassError.invalidState("Account is not portable")
        }
        guard let mask = handle.account.mask else {
            throw FidoPassError.invalidState("Portable account is missing its key material")
        }
        return combine(try fixedComponent(handle, using: derivation, pinProvider: pinProvider), mask)
    }

    /// The component this authenticator contributes. One touch.
    static func fixedComponent(_ handle: AccountHandle,
                               using derivation: SecretDeriving,
                               pinProvider: (@Sendable () -> String?)?) throws -> Data {
        let fixed = try derivation.deriveFixedComponent(handle, pinProvider: pinProvider)
        guard fixed.count == AccountRecord.maskByteCount else {
            throw FidoPassError.invalidState("Fixed component must be \(AccountRecord.maskByteCount) bytes")
        }
        return fixed
    }

    /// XOR, both ways: master key ⊕ fixed = external, external ⊕ fixed = master key.
    static func combine(_ left: Data, _ right: Data) -> Data {
        Data(zip(left, right).map { $0 ^ $1 })
    }
}
