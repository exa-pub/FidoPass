import SwiftUI

/// Shown once, because a menu-bar app with no Dock icon is easy to lose, and because the
/// three ideas behind FidoPass are not guessable from its interface.
struct OnboardingView: View {
    @ObservedObject var preferences: Preferences
    let launchAtLogin: LaunchAtLoginService
    let onFinish: () -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FidoPass lives in the menu bar")
                    .font(.title3.weight(.semibold))
                Text("Look for the key icon at the top right. Press \(preferences.hotkey.display) from anywhere to open it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                point(icon: "person.badge.key",
                      title: "Choose an account for an important password",
                      body: "Use an account for a vault master password, a disk key or a backup passphrase.")
                point(icon: "tag",
                      title: "The label is part of the password",
                      body: "The same key, account and label always produce the same password. A different label produces a different one, silently.")
                point(icon: "arrow.triangle.2.circlepath",
                      title: "Portable accounts survive a lost key",
                      body: "Their backup key can be entered on a second authenticator. A local account cannot be recovered by any means.")
                point(icon: "lock.shield",
                      title: "The key needs its own PIN",
                      body: "Use the security key’s PIN, not your Mac password. Too many wrong attempts block the key; resetting it erases its accounts.")
                point(icon: "doc.text",
                      title: "Keep a recovery sheet",
                      body: "It lists the account, the labels and the policy — and no secrets. Right-click an account to save one.")
            }

            LaunchAtLoginToggle("Start FidoPass at login", service: launchAtLogin)
            .help("Without this, the global shortcut only works after you start the app by hand.")

            HStack {
                Spacer()
                Button("Start using FidoPass") {
                    preferences.hasOnboarded = true
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func point(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
