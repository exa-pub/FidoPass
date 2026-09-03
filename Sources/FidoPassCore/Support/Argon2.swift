import Foundation
import CArgon2

/// argon2id, as the message-encryption format uses it.
///
/// The one file allowed to `import CArgon2`. Everything above it sees `Data` in and `Data`
/// out, exactly as `CLibfido2` never crosses out of `Devices/`.
///
/// The parameters are part of the `keyv1` format: a key URL's fingerprint, the locator that
/// names its account and the X25519 scalar behind its public key are all argon2id outputs,
/// and the same input has to give the same bytes on every machine, for ever. They were
/// chosen once, by measuring the reference implementation on an Apple M3 Max (~11 ms at
/// 32 MiB, one pass), and are **never calibrated at run time** — a faster or slower machine
/// simply waits a different number of milliseconds for the same answer.
enum Argon2 {

    struct Parameters: Hashable, Sendable {
        /// Passes over the memory (`t`).
        let timeCost: UInt32
        /// Memory in KiB (`m`).
        let memoryKiB: UInt32
        /// Lanes (`p`). The output depends on this as a parameter, not on how many threads
        /// actually run; the vendored build has no threads at all.
        let lanes: UInt32

        /// The set `keyv1` is defined with, for all three uses. Frozen — see the type comment.
        static let v1 = Parameters(timeCost: 1, memoryKiB: 32_768, lanes: 1)
    }

    /// Argon2 refuses shorter salts; every salt in the format is at least this long.
    static let minimumSaltByteCount = 8
    /// Argon2 refuses shorter tags; `keyfp` is 6 bytes, which is above it.
    static let minimumOutputByteCount = 4

    /// argon2id over `password` and `salt`, `outputByteCount` bytes of tag.
    ///
    /// The tag length is an input to argon2's initial hash, so a 6-byte tag is **not** the
    /// first six bytes of a 32-byte one. Callers ask for exactly the length the format
    /// defines.
    static func id(password: Data,
                   salt: Data,
                   parameters: Parameters = .v1,
                   outputByteCount: Int) throws -> Data {
        precondition(outputByteCount >= minimumOutputByteCount, "argon2 tags are at least \(minimumOutputByteCount) bytes")
        precondition(salt.count >= minimumSaltByteCount, "argon2 salts are at least \(minimumSaltByteCount) bytes")

        var output = [UInt8](repeating: 0, count: outputByteCount)
        let status: Int32 = password.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                argon2id_hash_raw(parameters.timeCost,
                                  parameters.memoryKiB,
                                  parameters.lanes,
                                  passwordBuffer.baseAddress,
                                  password.count,
                                  saltBuffer.baseAddress,
                                  salt.count,
                                  &output,
                                  outputByteCount)
            }
        }
        // ARGON2_OK is 0; every other code is negative and has a message.
        guard status == 0 else {
            throw FidoPassError.invalidState("argon2id failed: \(String(cString: argon2_error_message(status)))")
        }
        return Data(output)
    }
}
