import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Metrics shared by every HUD screen.
///
/// The width is fixed on purpose: a popover that changes width as its content changes reads
/// as a defect, and 340 pt is the widest a menu-bar panel can be before it stops feeling
/// like one.
enum HUDMetrics {
    static let width: CGFloat = 340
    static let maxContentHeight: CGFloat = 420
    static let corner: CGFloat = 12
    static let padding: CGFloat = 12
}

#if canImport(AppKit)
/// The system popover material, so the panel looks like every other menu-bar window.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#else
struct VisualEffectBackground: View {
    var body: some View { Color(nsColor: .windowBackgroundColor) }
}
#endif

/// The key is waiting for a finger.
///
/// Rendered inside the panel rather than as a floating window: the operation belongs to
/// what the user just clicked, and a separate window would need its own focus handling for
/// no gain.
struct TouchOverlayView: View {
    let prompt: TouchPrompt
    let onCancel: () -> Void

    @State private var pulsing = false
    @State private var elapsed: TimeInterval = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 54, height: 54)
                    .scaleEffect(pulsing ? 1.12 : 0.94)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }
            Text(prompt.title)
                .font(.headline)
            Text(prompt.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(prompt.deviceName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if elapsed >= 5 {
                // Some keys give no visible sign that they are waiting.
                Text("Press the blinking key.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, HUDMetrics.padding)
        .onAppear { pulsing = true }
        .onReceive(ticker) { _ in elapsed = Date().timeIntervalSince(prompt.startedAt) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(prompt.title). \(prompt.message)")
    }
}

/// The app is busy and the key needs no finger — PIN verification, mostly.
///
/// Without it the PIN screen simply stayed on screen while the key was being asked, which
/// reads as "nothing happened, type it again" — and typing it again is how PIN attempts get
/// spent.
struct HUDWaitingView: View {
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, HUDMetrics.padding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// One line of feedback under the content: what just happened, or what went wrong.
struct HUDFooterView: View {
    let status: String?
    let error: String?

    var body: some View {
        if let error {
            label(error, icon: "exclamationmark.triangle.fill", tint: .orange)
        } else if let status {
            label(status, icon: "checkmark.circle.fill", tint: .green)
        }
    }

    private func label(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, HUDMetrics.padding)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }
}

/// A screen title with a way back, used by every pushed screen.
struct HUDScreenHeader: View {
    let title: String
    var subtitle: String?
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HUDMetrics.padding)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// A warning that has to be read, not skimmed.
struct HUDWarningBox: View {
    let title: String
    let message: String
    var tint: Color = .orange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.28)))
    }
}
