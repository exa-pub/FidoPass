import Foundation

extension AccountsViewModel {
    func addRecentLabel(_ label: String) {
        recentLabels.removeAll { $0 == label }
        recentLabels.insert(label, at: 0)
        if recentLabels.count > 10 {
            recentLabels.removeLast(recentLabels.count - 10)
        }
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
