import Foundation
import CLibfido2

enum Libfido2Context {
    static func initialize() {
        fido_init(0)
    }

    static func check(_ rc: Int32, operation: String) throws {
        guard rc == FIDO_OK else {
            let message = String(cString: fido_strerr(rc))
            throw FidoPassError.libfido2("\(operation): \(message)")
        }
    }
}
