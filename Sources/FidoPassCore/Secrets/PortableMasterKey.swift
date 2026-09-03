import Foundation

/// A portable account's master key: the fixed component the key derives, XOR-ed with the
/// `external` half stored on the key. One touch to recover.
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
        guard let payload = handle.account.portable else {
            throw FidoPassError.invalidState("Portable account is missing its key material")
        }
        return combine(try fixedComponent(handle, using: derivation, pinProvider: pinProvider), payload.external)
    }

    /// The component this authenticator contributes. One touch.
    static func fixedComponent(_ handle: AccountHandle,
                               using derivation: SecretDeriving,
                               pinProvider: (@Sendable () -> String?)?) throws -> Data {
        let fixed = try derivation.deriveFixedComponent(handle, pinProvider: pinProvider)
        guard fixed.count == PortablePayload.externalByteCount else {
            throw FidoPassError.invalidState("Fixed component must be \(PortablePayload.externalByteCount) bytes")
        }
        return fixed
    }

    /// XOR, both ways: master key ⊕ fixed = external, external ⊕ fixed = master key.
    static func combine(_ left: Data, _ right: Data) -> Data {
        Data(zip(left, right).map { $0 ^ $1 })
    }
}
