import SwiftUI

struct KeyTouchPromptContainer<Content: View>: View {
    let configuration: KeyTouchPromptConfiguration?
    let content: Content

    init(configuration: KeyTouchPromptConfiguration?,
         @ViewBuilder content: () -> Content) {
        self.configuration = configuration
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .blur(radius: configuration == nil ? 0 : 3)
                .animation(.easeInOut(duration: 0.18), value: configuration == nil)
                .allowsHitTesting(configuration == nil)

            if let configuration {
                Rectangle()
                    .fill(Color.black.opacity(0.2))
                    .ignoresSafeArea()
                    .transition(.opacity)
                KeyTouchPromptView(configuration: configuration)
                    .transition(.scale(scale: 0.97, anchor: .center).combined(with: .opacity))
                    .padding(24)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: configuration != nil)
    }
}

private struct KeyTouchPromptView: View {
    let configuration: KeyTouchPromptConfiguration

    var body: some View {
        VStack(spacing: 18) {
            iconBadge
            VStack(spacing: 6) {
                Text(configuration.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(configuration.message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                if let accessory = configuration.accessory {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundColor(configuration.accent)
                        Text(accessory.text)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.top, 4)
                }
            }
            ProgressView()
                .progressViewStyle(.circular)
                .tint(configuration.accent)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 32)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(panelBackground)
                .shadow(color: Color.black.opacity(0.18), radius: 28, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(configuration.accent.opacity(0.18))
        )
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(configuration.accent.opacity(0.18))
                .frame(width: 64, height: 64)
            Circle()
                .stroke(configuration.accent.opacity(0.35), lineWidth: 2)
                .frame(width: 72, height: 72)
            Image(systemName: "touchid")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(configuration.accent)
        }
        .padding(.bottom, 4)
    }

    private var panelBackground: Color {
        #if canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #elseif canImport(UIKit)
        return Color(UIColor.systemBackground)
        #else
        return Color.white
        #endif
    }
}
