import Foundation
import FidoPassCore
import CLibfido2

public enum TestError: Error, Equatable {
    case generic(String)
}

extension TestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .generic(let message):
            return message
        }
    }
}

public final class InMemoryUbiquitousStore: NSUbiquitousKeyValueStore {
    private var storage: [String: Any] = [:]

    public override init() {
        super.init()
    }

    public override func set(_ anObject: Any?, forKey aKey: String) {
        storage[aKey] = anObject
    }

    public override func array(forKey aKey: String) -> [Any]? {
        storage[aKey] as? [Any]
    }

    public override func synchronize() -> Bool {
        true
    }
}

public final class MockDeviceRepository: DeviceRepositoryProtocol {
    public init() {}

    public var devices: [FidoDevice] = []
    public var listDevicesError: Error?
    public private(set) var listedLimits: [Int] = []

    public var withOpenedDeviceHandler: ((String?, (OpaquePointer, String) throws -> Any) throws -> Any)?
    public private(set) var withOpenedDevicePaths: [String?] = []

    public var ensureHmacSecretSupportedError: Error?
    public private(set) var ensureCalls: Int = 0

    public func listDevices(limit: Int) throws -> [FidoDevice] {
        listedLimits.append(limit)
        if let error = listDevicesError { throw error }
        return devices
    }

    public func withOpenedDevice<T>(path: String?, _ body: (OpaquePointer, String) throws -> T) throws -> T {
        withOpenedDevicePaths.append(path)
        if let handler = withOpenedDeviceHandler {
            guard let value = try handler(path, body) as? T else {
                throw TestError.generic("Unexpected handler return type")
            }
            return value
        }
        let pointer = OpaquePointer(bitPattern: 0xdeadbeef)!
        let resolvedPath = path ?? devices.first?.path ?? "/mock"
        return try body(pointer, resolvedPath)
    }

    public func ensureHmacSecretSupported(_ device: OpaquePointer) throws {
        ensureCalls += 1
        if let error = ensureHmacSecretSupportedError {
            throw error
        }
    }
}

public final class MockEnrollmentService: EnrollmentServiceProtocol {
    public struct EnrollCall: Equatable {
        public let accountId: String
        public let rpId: String
        public let userName: String
        public let requireUV: Bool
        public let residentKey: Bool
        public let devicePath: String?
    }

    public init() {}

    public var enrollClosure: ((String, String, String, Bool, Bool, String?, (() -> String?)?) throws -> Account)?
    public private(set) var enrollCalls: [EnrollCall] = []

    public var enumerateClosure: ((String, String, String?) throws -> [Account])?
    public private(set) var enumerateCalls: [(String, String, String?)] = []

    public var deleteClosure: ((Account, String?) throws -> Void)?
    public private(set) var deleteCalls: [(Account, String?)] = []

    public var updateClosure: ((Account, String, Bool, (() -> String?)?) throws -> Void)?
    public private(set) var updateCalls: [(Account, String, Bool)] = []

    public func enroll(accountId: String,
                       rpId: String,
                       userName: String,
                       requireUV: Bool,
                       residentKey: Bool,
                       devicePath: String?,
                       askPIN: (() -> String?)?) throws -> Account {
        enrollCalls.append(EnrollCall(accountId: accountId,
                                      rpId: rpId,
                                      userName: userName,
                                      requireUV: requireUV,
                                      residentKey: residentKey,
                                      devicePath: devicePath))
        if let closure = enrollClosure {
            return try closure(accountId, rpId, userName, requireUV, residentKey, devicePath, askPIN)
        }
        return Account(id: accountId,
                       rpId: rpId,
                       userName: userName,
                       credentialIdB64: Data(accountId.utf8).base64EncodedString(),
                       revision: 1,
                       policy: PasswordPolicy(),
                       devicePath: devicePath)
    }

    public func enumerateAccounts(rpId: String,
                                  devicePath: String,
                                  pin: String?) throws -> [Account] {
        enumerateCalls.append((rpId, devicePath, pin))
        if let closure = enumerateClosure {
            return try closure(rpId, devicePath, pin)
        }
        return []
    }

    public func deleteAccount(_ account: Account, pin: String?) throws {
        deleteCalls.append((account, pin))
        try deleteClosure?(account, pin)
    }

    public func updateCredentialUserName(account: Account,
                                         newUserName: String,
                                         requireUV: Bool,
                                         pinProvider: (() -> String?)?) throws {
        updateCalls.append((account, newUserName, requireUV))
        try updateClosure?(account, newUserName, requireUV, pinProvider)
    }
}

public final class MockPortableEnrollmentService: PortableEnrollmentServiceProtocol {
    public init() {}

    public var enrollPortableClosure: ((String, Bool, String?, (() -> String?)?, String?) throws -> (Account, String?))?
    public private(set) var enrollPortableCalls: [(String, Bool, String?)] = []

    public var exportClosure: ((Account, Bool, (() -> String?)?) throws -> String)?
    public private(set) var exportCalls: [(Account, Bool)] = []

    public func enrollPortable(accountId: String,
                               requireUV: Bool,
                               devicePath: String?,
                               askPIN: (() -> String?)?,
                               importedKeyB64: String?) throws -> (Account, String?) {
        enrollPortableCalls.append((accountId, requireUV, devicePath))
        if let closure = enrollPortableClosure {
            return try closure(accountId, requireUV, devicePath, askPIN, importedKeyB64)
        }
        return (Account(id: accountId,
                        rpId: "fidopass.portable",
                        userName: "",
                        credentialIdB64: Data(accountId.utf8).base64EncodedString(),
                        revision: 1,
                        policy: PasswordPolicy(),
                        devicePath: devicePath),
                nil)
    }

    public func exportImportedKey(_ account: Account,
                                  requireUV: Bool,
                                  pinProvider: (() -> String?)?) throws -> String {
        exportCalls.append((account, requireUV))
        if let closure = exportClosure {
            return try closure(account, requireUV, pinProvider)
        }
        return ""
    }
}

public final class MockSecretDerivationService: SecretDerivationServiceProtocol {
    public init() {}

    public var deriveSecretClosure: ((Account, String, Bool, (() -> String?)?) throws -> Data)?
    public private(set) var deriveSecretCalls: [(Account, String, Bool)] = []

    public var deriveFixedClosure: ((Account, Bool, (() -> String?)?) throws -> Data)?
    public private(set) var deriveFixedCalls: [(Account, Bool)] = []

    public func deriveSecret(account: Account,
                             label: String,
                             requireUV: Bool,
                             pinProvider: (() -> String?)?) throws -> Data {
        deriveSecretCalls.append((account, label, requireUV))
        if let closure = deriveSecretClosure {
            return try closure(account, label, requireUV, pinProvider)
        }
        return Data()
    }

    public func deriveFixedComponent(account: Account,
                                     requireUV: Bool,
                                     pinProvider: (() -> String?)?) throws -> Data {
        deriveFixedCalls.append((account, requireUV))
        if let closure = deriveFixedClosure {
            return try closure(account, requireUV, pinProvider)
        }
        return Data()
    }
}

public final class MockPasswordGenerator: PasswordGenerating {
    public init() {}

    public var generateClosure: ((Account, String, PasswordPolicy?, Bool, (() -> String?)?) throws -> String)?
    public private(set) var generateCalls: [(Account, String, PasswordPolicy?, Bool)] = []

    public func generatePassword(account: Account,
                                 label: String,
                                 policy override: PasswordPolicy?,
                                 requireUV: Bool,
                                 pinProvider: (() -> String?)?) throws -> String {
        generateCalls.append((account, label, override, requireUV))
        if let closure = generateClosure {
            return try closure(account, label, override, requireUV, pinProvider)
        }
        return "password"
    }
}

public extension Account {
    static func fixture(id: String = "account",
                        rpId: String = "fidopass.local",
                        userName: String = "user",
                        credentialId: Data? = nil,
                        revision: Int = 1,
                        policy: PasswordPolicy = PasswordPolicy(),
                        devicePath: String? = "/dev/mock") -> Account {
        let credential = credentialId ?? Data(id.utf8)
        return Account(id: id,
                       rpId: rpId,
                       userName: userName,
                       credentialIdB64: credential.base64EncodedString(),
                       revision: revision,
                       policy: policy,
                       devicePath: devicePath)
    }
}
