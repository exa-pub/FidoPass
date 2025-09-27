import SwiftUI

struct StatusBanner: View {
    let icon: String?
    let color: Color
    let message: String
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(color)
            } else if let icon {
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(message)
                .font(.callout)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.28))
        )
    }
}
