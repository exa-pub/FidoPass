import Foundation

/// Recovers a portable master key as fixed component XOR mask, for both account layouts.
enum PortableMasterKey {

    /// Recovers the master key. One touch, for the fixed component.
    static func recover(_ handle: AccountHandle,
                        using derivation: SecretDeriving,
                        pinProvider: (@Sendable () -> String?)?) throws -> Data {
        try handle.account.validateForDerivation()
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
