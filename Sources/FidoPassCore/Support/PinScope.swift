import Foundation

/// Hands a PIN to libfido2 as a C string and guarantees it is wiped afterwards.
///
/// libfido2 takes `const char *`, so the Swift string has to be copied onto the heap. The
/// copy used to be released with a bare `free`, leaving the PIN readable in freed memory.
/// Routing every call through this helper keeps the wipe next to the allocation.
enum PinScope {
    static func withPIN<T>(_ pin: String?, _ body: (UnsafePointer<CChar>?) throws -> T) throws -> T {
        guard let pin else { return try body(nil) }
        if let issue = PinPolicy.validateExisting(pin) { throw FidoPassError.invalidState(issue.message) }
        guard let copy = strdup(pin) else { throw FidoPassError.invalidState("Could not allocate a PIN buffer") }
        defer {
            let length = strlen(copy)
            memset_s(copy, length, 0, length)
            free(copy)
        }
        return try body(UnsafePointer(copy))
    }
}
