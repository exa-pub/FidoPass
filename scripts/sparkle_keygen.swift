// Makes the Sparkle signing key without touching any keychain.
//
//   swift scripts/sparkle_keygen.swift <private-key-file>
//
// Writes the private key — the base64 of a 32-byte Ed25519 seed, the format Sparkle's
// `sign_update --ed-key-file` and `generate_appcast --ed-key-file` read — to the given path,
// readable by the owner only, and prints the public key for scripts/release.env.
//
// Sparkle's own `generate_keys` does the same job through the login keychain. This script
// exists so that the key can be made on a machine whose keychain is not to be involved, and
// so that the whole trust path is CryptoKit plus Sparkle's documented file format.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: sparkle_keygen.swift <private-key-file>\n".utf8))
    exit(2)
}
let path = arguments[1]
guard !FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write(Data("sparkle_keygen: \(path) exists; refusing to overwrite a signing key\n".utf8))
    exit(2)
}

let key = Curve25519.Signing.PrivateKey()
let seed = key.rawRepresentation.base64EncodedString()
let created = FileManager.default.createFile(atPath: path,
                                             contents: Data(seed.utf8),
                                             attributes: [.posixPermissions: 0o600])
guard created else {
    FileHandle.standardError.write(Data("sparkle_keygen: cannot write \(path)\n".utf8))
    exit(2)
}

print("""
Private key written to \(path) (keep it offline; it is the SPARKLE_PRIVATE_KEY secret).
Public key for scripts/release.env:

SPARKLE_PUBLIC_KEY=\(key.publicKey.rawRepresentation.base64EncodedString())
""")
