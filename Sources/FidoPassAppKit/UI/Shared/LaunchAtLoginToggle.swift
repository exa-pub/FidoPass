import SwiftUI

struct LaunchAtLoginToggle: View {
    @StateObject private var model: LaunchAtLoginModel
    @Environment(\.scenePhase) private var scenePhase
    let title: String

    init(_ title: String, service: any LaunchAtLoginService) {
        self.title = title
        _model = StateObject(wrappedValue: LaunchAtLoginModel(service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(get: { model.status == .enabled }, set: { model.setEnabled($0) }))
            if model.status == .requiresApproval {
                Text("Allow FidoPass in System Settings → General → Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { model.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.reload() } }
    }
}
