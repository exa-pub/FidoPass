// Verifies a Sparkle EdDSA signature with CryptoKit — no third-party code on the trust path.
//
//   swift scripts/ed25519_verify.swift <public-key-base64> <signature-base64> <file>
//
// Exits 0 when the signature is valid for the file's bytes, 1 when it is not, 2 on bad input.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicKey = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]) else {
    FileHandle.standardError.write(Data("usage: ed25519_verify.swift <public-key-base64> <signature-base64> <file>\n".utf8))
    exit(2)
}
guard let data = FileManager.default.contents(atPath: arguments[3]) else {
    FileHandle.standardError.write(Data("ed25519_verify: cannot read \(arguments[3])\n".utf8))
    exit(2)
}
guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
    FileHandle.standardError.write(Data("ed25519_verify: the public key is not 32 raw bytes\n".utf8))
    exit(2)
}
exit(key.isValidSignature(signature, for: data) ? 0 : 1)
