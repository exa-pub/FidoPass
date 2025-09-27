import Foundation
import Security

public final class KeychainStore {
    private let service: String
    public init(service: String) { self.service = service }

    private func describeStatus(_ status: OSStatus) -> String {
        if let msg = SecCopyErrorMessageString(status, nil) as String? { return msg }
        return "OSStatus=\(status)"
    }

    // keychain key = accountId
    private func baseQuery(accountId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId
        ]
    }

    public func save(account: Account) throws {
        let data = try JSONEncoder().encode(account)
        var q = baseQuery(accountId: account.id)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        var status = SecItemAdd(q.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(baseQuery(accountId: account.id) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        if status != errSecSuccess {
            throw FidoPassError.invalidState("Keychain error: \(status)")
        }
    }

    public func load(accountId: String) throws -> Account? {
        var q = baseQuery(accountId: accountId)
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw FidoPassError.invalidState("Keychain get error: \(status)")
        }
        return try JSONDecoder().decode(Account.self, from: data)
    }

    public func list() throws -> [Account] {
        // We try several query variants because some macOS setups return errSecParam (-50) for otherwise valid combos.
        enum Variant: String, CaseIterable { case attributesAndData, attributesOnly, dataOnly, refs }

        func makeQuery(_ variant: Variant) -> [String: Any] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            switch variant {
            case .attributesAndData:
                q[kSecReturnAttributes as String] = kCFBooleanTrue
                q[kSecReturnData as String] = kCFBooleanTrue
            case .attributesOnly:
                q[kSecReturnAttributes as String] = kCFBooleanTrue
            case .dataOnly:
                q[kSecReturnData as String] = kCFBooleanTrue
            case .refs:
                q[kSecReturnRef as String] = kCFBooleanTrue
            }
            return q
        }

        var collected: [Account] = []
        var errors: [String] = []

        for variant in Variant.allCases {
            var out: CFTypeRef?
            let status = SecItemCopyMatching(makeQuery(variant) as CFDictionary, &out)
            if status == errSecItemNotFound { return [] }
            if status != errSecSuccess {
                errors.append("variant=\(variant.rawValue) -> \(describeStatus(status))")
                continue
            }
            switch variant {
            case .attributesAndData:
                if let array = out as? [[String: Any]] {
                    collected = array.compactMap { item in
                        guard let data = item[kSecValueData as String] as? Data else { return nil }
                        return try? JSONDecoder().decode(Account.self, from: data)
                    }
                }
            case .attributesOnly:
                if let array = out as? [[String: Any]] {
                    let ids = array.compactMap { $0[kSecAttrAccount as String] as? String }
                    collected = ids.compactMap { try? load(accountId: $0) }
                }
            case .dataOnly:
                if let arr = out as? [Data] {
                    collected = arr.compactMap { try? JSONDecoder().decode(Account.self, from: $0) }
                }
            case .refs:
                // We have item refs; extract account IDs individually.
                if let refs = out as? [SecKeychainItem] { // generic cast; if it fails skip
                    var accs: [Account] = []
                    for ref in refs {
                        // Query each by extracting attributes
                        var attrOut: CFTypeRef?
                        let singleQuery: [String: Any] = [
                            kSecClass as String: kSecClassGenericPassword,
                            kSecReturnData as String: kCFBooleanTrue as Any,
                            kSecValueRef as String: ref
                        ]
                        let st = SecItemCopyMatching(singleQuery as CFDictionary, &attrOut)
                        if st == errSecSuccess, let data = attrOut as? Data, let model = try? JSONDecoder().decode(Account.self, from: data) {
                            accs.append(model)
                        }
                    }
                    collected = accs
                }
            }
            if !collected.isEmpty { break }
        }

        if collected.isEmpty && !errors.isEmpty {
            throw FidoPassError.invalidState("Keychain list error (all variants failed): \(errors.joined(separator: "; "))")
        }
        return collected.sorted { $0.id < $1.id }
    }

    public func remove(accountId: String) throws {
        let status = SecItemDelete(baseQuery(accountId: accountId) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw FidoPassError.invalidState("Keychain delete error: \(status)")
        }
    }
}
