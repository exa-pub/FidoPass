import Foundation

/// Hands a PIN to libfido2 as a C string and guarantees it is wiped afterwards.
///
/// libfido2 takes `const char *`, so the Swift string has to be copied onto the heap. The
/// copy used to be released with a bare `free`, leaving the PIN readable in freed memory.
/// Routing every call through this helper keeps the wipe next to the allocation.
enum PinScope {
    static func withPIN<T>(_ pin: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        guard let pin, let copy = strdup(pin) else {
            return try body(nil)
        }
        defer {
            let length = strlen(copy)
            memset_s(copy, length, 0, length)
            free(copy)
        }
        return try body(UnsafePointer(copy))
    }
}
