import Foundation
import FidoPassCore

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

    public override func set(_ aData: Data?, forKey aKey: String) {
        storage[aKey] = aData
    }

    public override func removeObject(forKey aKey: String) {
        storage.removeValue(forKey: aKey)
    }

    public override func array(forKey aKey: String) -> [Any]? {
        storage[aKey] as? [Any]
    }

    public override func data(forKey aKey: String) -> Data? {
        storage[aKey] as? Data
    }

    public override func synchronize() -> Bool {
        true
    }
}

public final class MockDeviceLister: DeviceListing, @unchecked Sendable {
    public init() {}

    public var devices: [FidoDevice] = []
    public var listDevicesError: Error?
    public private(set) var listCalls = 0

    public func listDevices() throws -> [FidoDevice] {
        listCalls += 1
        if let error = listDevicesError { throw error }
        return devices
    }
}

public final class MockEnrollmentService: Enrolling, @unchecked Sendable {
    public struct EnrollCall: Equatable {
        public let accountId: String
        public let kind: AccountKind
        public let devicePath: String
    }

    public init() {}

    public var enrollClosure: ((String, AccountKind, String, (@Sendable () -> String?)?) throws -> AccountHandle)?
    public private(set) var enrollCalls: [EnrollCall] = []

    public var enumerateClosure: ((String, String, String?) throws -> [AccountHandle])?
    public private(set) var enumerateCalls: [(String, String, String?)] = []

    public var deleteClosure: ((AccountHandle, String?) throws -> Void)?
    public private(set) var deleteCalls: [(AccountHandle, String?)] = []

    public var updateClosure: ((AccountHandle, (@Sendable () -> String?)?) throws -> Void)?
    public private(set) var updateCalls: [AccountHandle] = []

    public func enroll(accountId: String,
                       kind: AccountKind,
                       devicePath: String,
                       askPIN: (@Sendable () -> String?)?) throws -> AccountHandle {
        enrollCalls.append(EnrollCall(accountId: accountId, kind: kind, devicePath: devicePath))
        if let closure = enrollClosure {
            return try closure(accountId, kind, devicePath, askPIN)
        }
        return AccountHandle.fixture(id: accountId, kind: kind, devicePath: devicePath)
    }

    public func enumerateAccounts(rpId: String,
                                  devicePath: String,
                                  pin: String?) throws -> [AccountHandle] {
        enumerateCalls.append((rpId, devicePath, pin))
        if let closure = enumerateClosure {
            return try closure(rpId, devicePath, pin)
        }
        return []
    }

    public func deleteAccount(_ handle: AccountHandle, pin: String?) throws {
        deleteCalls.append((handle, pin))
        try deleteClosure?(handle, pin)
    }

    public func updateCredentialUserInfo(_ handle: AccountHandle,
                                         pinProvider: (@Sendable () -> String?)?) throws {
        updateCalls.append(handle)
        try updateClosure?(handle, pinProvider)
    }
}

public final class MockPortableEnrollmentService: PortableEnrolling, @unchecked Sendable {
    public init() {}

    public var enrollPortableClosure: ((String, String, (@Sendable () -> String?)?, String?) throws -> (AccountHandle, String?))?
    public private(set) var reportedSteps: [PortableEnrollmentStep] = []
    public private(set) var enrollPortableCalls: [(String, String)] = []

    public var exportClosure: ((AccountHandle, (@Sendable () -> String?)?) throws -> String)?
    public private(set) var exportCalls: [AccountHandle] = []

    public func enrollPortable(accountId: String,
                               devicePath: String,
                               askPIN: (@Sendable () -> String?)?,
                               importedKeyB64: String?,
                               onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (AccountHandle, String?) {
        enrollPortableCalls.append((accountId, devicePath))
        onStep.map { report in [PortableEnrollmentStep.creatingCredential].forEach(report) }
        if let closure = enrollPortableClosure {
            return try closure(accountId, devicePath, askPIN, importedKeyB64)
        }
        return (AccountHandle.fixture(id: accountId, kind: .portable, devicePath: devicePath), nil)
    }

    public func exportImportedKey(_ handle: AccountHandle,
                                  pinProvider: (@Sendable () -> String?)?) throws -> String {
        exportCalls.append(handle)
        if let closure = exportClosure {
            return try closure(handle, pinProvider)
        }
        return ""
    }
}

public final class MockSecretDerivationService: SecretDeriving, @unchecked Sendable {
    public init() {}

    public var deriveSecretClosure: ((AccountHandle, String, Int, (@Sendable () -> String?)?) throws -> Data)?
    public private(set) var deriveSecretCalls: [(AccountHandle, String, Int)] = []

    public var deriveFixedClosure: ((AccountHandle, (@Sendable () -> String?)?) throws -> Data)?
    public private(set) var deriveFixedCalls: [AccountHandle] = []

    public func deriveSecret(_ handle: AccountHandle,
                             label: String,
                             revision: Int,
                             pinProvider: (@Sendable () -> String?)?) throws -> Data {
        deriveSecretCalls.append((handle, label, revision))
        if let closure = deriveSecretClosure {
            return try closure(handle, label, revision, pinProvider)
        }
        return Data()
    }

    public func deriveFixedComponent(_ handle: AccountHandle,
                                     pinProvider: (@Sendable () -> String?)?) throws -> Data {
        deriveFixedCalls.append(handle)
        if let closure = deriveFixedClosure {
            return try closure(handle, pinProvider)
        }
        return Data()
    }
}

public final class MockPasswordGenerator: PasswordGenerating, @unchecked Sendable {
    public init() {}

    public var generateClosure: ((AccountHandle, String, DerivationParameters, (@Sendable () -> String?)?) throws -> String)?
    public private(set) var generateCalls: [(AccountHandle, String, DerivationParameters)] = []

    public func generatePassword(_ handle: AccountHandle,
                                 label: String,
                                 parameters: DerivationParameters,
                                 pinProvider: (@Sendable () -> String?)?) throws -> String {
        generateCalls.append((handle, label, parameters))
        if let closure = generateClosure {
            return try closure(handle, label, parameters, pinProvider)
        }
        return "password"
    }
}

public extension Account {
    static func fixture(id: String = "account",
                        kind: AccountKind = .local,
                        credentialId: Data? = nil,
                        portable: PortablePayload? = nil) -> Account {
        Account(id: id,
                kind: kind,
                credentialIdB64: (credentialId ?? Data(id.utf8)).base64EncodedString(),
                portable: portable)
    }
}

public extension AccountHandle {
    static func fixture(id: String = "account",
                        kind: AccountKind = .local,
                        credentialId: Data? = nil,
                        devicePath: String = "/dev/mock",
                        portable: PortablePayload? = nil) -> AccountHandle {
        AccountHandle(account: .fixture(id: id, kind: kind, credentialId: credentialId, portable: portable),
                      devicePath: devicePath)
    }
}
