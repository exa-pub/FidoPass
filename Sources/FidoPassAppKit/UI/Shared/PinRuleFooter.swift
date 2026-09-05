import SwiftUI
import FidoPassCore

/// The rule being broken, or the rule to satisfy.
///
/// One line that changes rather than two that compete: showing the requirement and the
/// complaint at once makes the reader work out which one applies to them.
struct PinRuleFooter: View {
    @ObservedObject var form: PinFormModel

    var body: some View {
        if let issue = form.issue {
            Text(issue)
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("At least \(form.policy.minimumCodePoints) characters, at most \(PinPolicy.maxLengthBytes) bytes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
