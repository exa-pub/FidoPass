import XCTest

/// Test-owned containers and preferences end with the test, just as app windows do.
class AppTestCase: XCTestCase {
    override func tearDown() async throws {
        await AppTestFactory.cleanUp()
        try await super.tearDown()
    }
}
