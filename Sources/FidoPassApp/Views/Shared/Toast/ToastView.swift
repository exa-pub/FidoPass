import SwiftUI

struct ToastView: View {
    let toast: AccountsViewModel.ToastMessage

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = toast.icon {
                Image(systemName: icon)
                    .symbolVariant(.fill)
                    .font(.title3)
                    .foregroundColor(toast.style.tintColor)
                    .frame(width: 28, height: 28)
                    .background(toast.style.tintColor.opacity(0.12), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                if let subtitle = toast.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(toast.style.tintColor)
                .frame(width: 4)
                .padding(.vertical, 10)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 12)
    }
}
