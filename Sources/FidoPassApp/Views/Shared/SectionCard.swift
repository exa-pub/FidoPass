import SwiftUI

struct SectionCard<Content: View>: View {
    let icon: String
    let title: String
    let accent: Color
    let subtitle: String?
    let trailing: AnyView?
    let content: Content

    init(icon: String,
         title: String,
         accent: Color = .accentColor,
         subtitle: String? = nil,
         trailing: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.accent = accent
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(accent)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .textSelection(.enabled)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    trailing
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .cardDecoration()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
