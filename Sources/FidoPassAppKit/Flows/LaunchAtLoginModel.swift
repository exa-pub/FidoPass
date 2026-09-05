import Foundation

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var error: String?
    private let service: any LaunchAtLoginService

    init(service: any LaunchAtLoginService) {
        self.service = service
        status = service.status
    }

    func reload() { status = service.status }
    func setEnabled(_ enabled: Bool) {
        error = nil
        do { try service.setEnabled(enabled) }
        catch { self.error = error.localizedDescription }
        reload()
    }
}
