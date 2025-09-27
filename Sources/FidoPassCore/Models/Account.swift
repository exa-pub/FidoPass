import Foundation

public struct Account: Codable, Hashable, Identifiable {
    public var id: String
    public var rpId: String
    public var userName: String
    public var credentialIdB64: String
    public var revision: Int
    public var policy: PasswordPolicy
    public var devicePath: String?

    public static func ==(lhs: Account, rhs: Account) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
