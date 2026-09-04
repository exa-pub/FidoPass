import Foundation
import CLibfido2

/// Per-credential records in the shared large-blob array. libfido2 handles encryption
/// and raw DEFLATE using the credential’s largeBlobKey, which stays in Core.
/// Reads need no PIN or touch; writes and removal require PIN authentication.
enum LargeBlobStore {

    /// The entry sealed under `key`, or `nil` when the store holds none for it.
    static func read(device: OpaquePointer, key: Data) throws -> Data? {
        var buffer: UnsafeMutablePointer<UInt8>?
        var length: size_t = 0
        let rc = key.withUnsafeBytes { pointer in
            fido_dev_largeblob_get(device,
                                   pointer.bindMemory(to: UInt8.self).baseAddress,
                                   key.count,
                                   &buffer,
                                   &length)
        }
        // Allocated by libfido2 on success; ours to release.
        defer { if let buffer { free(buffer) } }
        if rc == FIDO_ERR_NOTFOUND { return nil }
        try Libfido2Context.check(rc, operation: "largeblob_get")
        guard let buffer else { return Data() }
        return Data(bytes: buffer, count: length)
    }

    /// Writes `blob` as the entry for `key`, replacing any existing one. PIN, no touch.
    static func write(device: OpaquePointer, key: Data, blob: Data, pin: String?) throws {
        let rc = try PinScope.withPIN(pin) { pinCString in
            key.withUnsafeBytes { keyPointer in
                blob.withUnsafeBytes { blobPointer in
                    fido_dev_largeblob_set(device,
                                           keyPointer.bindMemory(to: UInt8.self).baseAddress,
                                           key.count,
                                           blobPointer.bindMemory(to: UInt8.self).baseAddress,
                                           blob.count,
                                           pinCString)
                }
            }
        }
        if rc == FIDO_ERR_LARGEBLOB_STORAGE_FULL {
            throw FidoPassError.unsupported("The key's large-blob store is full — delete an account you no longer use")
        }
        try Libfido2Context.check(rc, operation: "largeblob_set")
    }

    /// Removes the entry for `key`. Nothing to remove is not an error: the record is gone
    /// either way. The credential was already deleted; a failure leaves an encrypted orphan.
    static func remove(device: OpaquePointer, key: Data, pin: String?) throws {
        let rc = try PinScope.withPIN(pin) { pinCString in
            key.withUnsafeBytes { pointer in
                fido_dev_largeblob_remove(device,
                                          pointer.bindMemory(to: UInt8.self).baseAddress,
                                          key.count,
                                          pinCString)
            }
        }
        if rc == FIDO_ERR_NOTFOUND { return }
        try Libfido2Context.check(rc, operation: "largeblob_remove")
    }

    /// The large-blob key of an open credential object — from `makeCredential` or from
    /// credential management — or `nil` when it has none.
    static func key(of credential: OpaquePointer) -> Data? {
        let length = fido_cred_largeblob_key_len(credential)
        guard length > 0, let pointer = fido_cred_largeblob_key_ptr(credential) else { return nil }
        return Data(bytes: pointer, count: length)
    }
}
