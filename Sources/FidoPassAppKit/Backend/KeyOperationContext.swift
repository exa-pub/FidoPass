import Foundation

enum KeyOperationContext {
    @TaskLocal static var lease: OperationLease?
    static func check(_ lifetime: OperationLease? = nil) throws {
        try Task.checkCancellation()
        try lease?.check()
        try lifetime?.check()
    }
}
