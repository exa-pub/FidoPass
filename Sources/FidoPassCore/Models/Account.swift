import Foundation

public struct Account: Codable, Hashable, Identifiable {
    public var id: String
    public var rpId: String
    public var userName: String
    public var credentialIdB64: String
    public var revision: Int
    public var policy: PasswordPolicy
    public var devicePath: String?

    public init(id: String,
                rpId: String,
                userName: String,
                credentialIdB64: String,
                revision: Int,
                policy: PasswordPolicy,
                devicePath: String?) {
        self.id = id
        self.rpId = rpId
        self.userName = userName
        self.credentialIdB64 = credentialIdB64
        self.revision = revision
        self.policy = policy
        self.devicePath = devicePath
    }

    public static func ==(lhs: Account, rhs: Account) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
