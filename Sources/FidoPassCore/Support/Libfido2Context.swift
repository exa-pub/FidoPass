import Foundation
import CLibfido2

enum Libfido2Context {
    /// `fido_init` runs once per process, however many cores and repositories are built —
    /// tests build several.
    private static let initialized: Void = { fido_init(0) }()

    static func initialize() {
        _ = initialized
    }

    static func check(_ rc: Int32, operation: String) throws {
        guard rc == FIDO_OK else {
            throw FidoPassError.libfido2(operation: operation,
                                         status: FidoStatus(code: rc),
                                         message: String(cString: fido_strerr(rc)))
        }
    }

    /// `check` for credential management, where the two "this key is too old for that"
    /// codes become a sentence that says so instead of a raw status.
    static func checkCredman(_ rc: Int32, operation: String) throws {
        if rc == FIDO_ERR_INVALID_COMMAND || rc == FIDO_ERR_UNSUPPORTED_OPTION {
            throw FidoPassError.unsupported("This key does not support credential management")
        }
        try check(rc, operation: operation)
    }
}
