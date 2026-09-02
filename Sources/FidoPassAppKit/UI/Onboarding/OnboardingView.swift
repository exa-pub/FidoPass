import SwiftUI

/// Shown once, because a menu-bar app with no Dock icon is easy to lose, and because the
/// three ideas behind FidoPass are not guessable from its interface.
struct OnboardingView: View {
    @ObservedObject var preferences: Preferences
    let launchAtLogin: LaunchAtLoginService
    let onFinish: () -> Void

    @State private var startsAtLogin = false

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
                      title: "An account is a derivation identity",
                      body: "Not a website. A vault master password, a disk key, a backup passphrase — one or two is the normal number.")
                point(icon: "tag",
                      title: "The label is part of the password",
                      body: "The same key, account and label always produce the same password. A different label produces a different one, silently.")
                point(icon: "arrow.triangle.2.circlepath",
                      title: "Portable accounts survive a lost key",
                      body: "Their backup key can be entered on a second authenticator. A local account cannot be recovered by any means.")
                point(icon: "lock.shield",
                      title: "The key needs its own PIN",
                      body: "Not your Mac password. FidoPass sets one on a new key and can change it later — but eight wrong entries in a row lock the key for good.")
                point(icon: "doc.text",
                      title: "Keep a recovery sheet",
                      body: "It lists the account, the labels and the policy — and no secrets. Right-click an account to save one.")
            }

            Toggle("Start FidoPass at login", isOn: Binding(get: { startsAtLogin },
                                                            set: { newValue in
                                                                startsAtLogin = newValue
                                                                launchAtLogin.setEnabled(newValue)
                                                            }))
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
        .onAppear { startsAtLogin = launchAtLogin.isEnabled }
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
