import Foundation
import FidoPassCore
#if canImport(AppKit)
import AppKit
#endif

extension AccountsViewModel {
    func addRecentLabel(_ label: String) {
        recentLabels.removeAll { $0 == label }
        recentLabels.insert(label, at: 0)
        if recentLabels.count > 10 {
            recentLabels.removeLast(recentLabels.count - 10)
        }
        saveRecentLabels()
    }

    /// Clears the history in memory *and* in storage.
    ///
    /// Wiping only the published array left the values in UserDefaults and iCloud, so they
    /// reappeared on the next launch — or immediately, once the iCloud store notified a
    /// change.
    func clearRecentLabels() {
        recentLabels.removeAll()
        saveRecentLabels()
    }

    func saveRecentLabels() {
        let value = recentLabels
        userDefaults.set(value, forKey: userDefaultsKey)
        ubiStore.set(value, forKey: ubiquitousKey)
        ubiStore.synchronize()
    }

    func loadRecentLabels() {
        var local = (userDefaults.array(forKey: userDefaultsKey) as? [String]) ?? []
        if let cloud = ubiStore.array(forKey: ubiquitousKey) as? [String] {
            for label in cloud.reversed() where !local.contains(label) {
                local.insert(label, at: 0)
            }
        }
        recentLabels = Array(local.prefix(10))
    }

    func mergeUbiquitous() {
        let before = Set(recentLabels)
        if let cloud = ubiStore.array(forKey: ubiquitousKey) as? [String] {
            var merged = recentLabels
            for label in cloud where !merged.contains(label) {
                merged.append(label)
            }
            recentLabels = Array(merged.prefix(10))
            if Set(recentLabels) != before {
                userDefaults.set(recentLabels, forKey: userDefaultsKey)
            }
        }
    }
}

extension AccountsViewModel {
    /// Builds the recovery sheet for an account and offers to save it.
    ///
    /// Everything on it is non-secret, which is the point: it can be printed and kept with
    /// the key instead of being guarded separately.
    func exportRecoverySheet(for account: Account) {
        let deviceDescription = account.devicePath
            .flatMap { deviceStates[$0]?.device }
            .map { "\($0.displayName) — \($0.identityLabel)" }
        let sheet = RecoverySheet(account: account,
                                  labels: recentLabels,
                                  deviceDescription: deviceDescription)
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sheet.suggestedFileName
        panel.allowedContentTypes = [.plainText]
        panel.message = "This sheet contains no passwords, PIN or backup key."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sheet.render().write(to: url, atomically: true, encoding: .utf8)
            showToast("Recovery sheet saved", icon: "doc.text", style: .success)
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }
}
