import XCTest
@testable import FidoPassAppKit

@MainActor
final class LaunchAtLoginTests: AppTestCase {
    func testLaunchAtLoginReportsActualStatusOnFailureAndExternalChange() {
        let service = LoginService()
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(true)
        XCTAssertEqual(model.status, .disabled)
        XCTAssertNotNil(model.error)
        service.status = .requiresApproval
        model.reload()
        XCTAssertEqual(model.status, .requiresApproval)
        service.fail = false
        model.setEnabled(true)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertNil(model.error)
    }
}

@MainActor
private final class LoginService: LaunchAtLoginService {
    var status: LaunchAtLoginStatus = .disabled
    var fail = true
    func setEnabled(_ enabled: Bool) throws {
        if fail { throw NSError(domain: "SyntheticLoginFailure", code: 1) }
        status = enabled ? .enabled : .disabled
    }
}
