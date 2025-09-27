import SwiftUI
import FidoPassCore

struct DeviceAvatarView: View {
    let device: FidoDevice
    let isLocked: Bool

    var body: some View {
        let circleColor = isLocked ? Color.secondary.opacity(0.14) : Color.green.opacity(0.18)
        let symbolColor = isLocked ? Color.secondary : Color.green
        Circle()
            .fill(circleColor)
            .frame(width: 38, height: 38)
            .overlay(
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(symbolColor)
            )
            .accessibilityHidden(true)
    }
}
