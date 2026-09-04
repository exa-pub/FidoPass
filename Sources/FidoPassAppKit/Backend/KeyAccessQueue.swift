import FidoPassCore
import Foundation

/// Serializes blocking libfido2 calls off the cooperative executor.
/// A call retains the queue until it returns, including after UI abandonment.
final class KeyAccessQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fidopass.keyAccess", qos: .userInitiated)

    func run<T: Sendable>(validity: OperationLease? = nil,
                          _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let cancellation = OperationLease()
        let owner = KeyOperationContext.lease
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: T = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        try owner?.check()
                        try validity?.check()
                        let value = try body()
                        try cancellation.check()
                        try owner?.check()
                        try validity?.check()
                        return value
                    })
                }
            }
            try KeyOperationContext.check(validity)
            return result
        } onCancel: { cancellation.invalidate() }
    }
}
