import Foundation

@MainActor
protocol LaunchAtLoginService: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ enabled: Bool) throws
}
