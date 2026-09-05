import Foundation
import XCTest

@MainActor
func waitUntil(timeout: Duration = .seconds(5),
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting for test state", file: file, line: line)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
