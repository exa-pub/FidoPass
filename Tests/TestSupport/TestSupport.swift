import Foundation
import FidoPassCore

public enum TestError: Error, Equatable, Sendable {
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
        public let identity: AccountIdentity
        public let devicePath: String
        public let namesakePolicy: NamesakePolicy
    }

    public init() {}

    public var enrollClosure: ((String, AccountKind, AccountIdentity, String, (@Sendable () -> String?)?, NamesakePolicy) throws -> AccountHandle)?
    public private(set) var enrollCalls: [EnrollCall] = []

    public var enumerateClosure: ((String, String?) throws -> [AccountHandle])?
    public private(set) var enumerateCalls: [(String, String?)] = []

    public var deleteClosure: ((AccountHandle, String?) throws -> Void)?
    public private(set) var deleteCalls: [(AccountHandle, String?)] = []

    public var writeRecordClosure: ((AccountHandle, (@Sendable () -> String?)?) throws -> Void)?
    public private(set) var writeRecordCalls: [AccountHandle] = []

    /// Every call in the order it happened, by name — for tests about ordering, where the
    /// per-method lists cannot say which came first.
    public private(set) var callLog: [String] = []

    public func enroll(accountId: String,
                       kind: AccountKind,
                       identity: AccountIdentity,
                       devicePath: String,
                       askPIN: (@Sendable () -> String?)?,
                       namesakePolicy: NamesakePolicy) throws -> AccountHandle {
        enrollCalls.append(EnrollCall(accountId: accountId, kind: kind, identity: identity, devicePath: devicePath, namesakePolicy: namesakePolicy))
        callLog.append("enroll(\(accountId))")
        if let closure = enrollClosure {
            return try closure(accountId, kind, identity, devicePath, askPIN, namesakePolicy)
        }
        return AccountHandle.v2Fixture(id: accountId, kind: kind, identity: identity, devicePath: devicePath,
                                       integrity: kind == .local ? .ok : .recordMissing)
    }

    public func enumerateAccounts(devicePath: String,
                                  pin: String?) throws -> [AccountHandle] {
        enumerateCalls.append((devicePath, pin))
        callLog.append("enumerate")
        if let closure = enumerateClosure {
            return try closure(devicePath, pin)
        }
        return []
    }

    public func deleteAccount(_ handle: AccountHandle, pin: String?) throws {
        deleteCalls.append((handle, pin))
        callLog.append("delete(\(handle.id):\(handle.account.format.rawValue))")
        try deleteClosure?(handle, pin)
    }

    public func writeRecord(for handle: AccountHandle,
                            pinProvider: (@Sendable () -> String?)?) throws {
        writeRecordCalls.append(handle)
        callLog.append("writeRecord(\(handle.id))")
        try writeRecordClosure?(handle, pinProvider)
    }
}

public final class MockPortableEnrollmentService: PortableEnrolling, @unchecked Sendable {
    public init() {}

    public var enrollPortableClosure: ((String, AccountIdentity, String, (@Sendable () -> String?)?, PortableBackup?) throws -> (AccountHandle, PortableBackup?))?
    public private(set) var reportedSteps: [PortableEnrollmentStep] = []
    public private(set) var enrollPortableCalls: [(String, AccountIdentity, String)] = []

    public var exportClosure: ((AccountHandle, (@Sendable () -> String?)?) throws -> PortableBackup)?
    public private(set) var exportCalls: [AccountHandle] = []

    public func enrollPortable(accountId: String,
                               identity: AccountIdentity,
                               devicePath: String,
                               askPIN: (@Sendable () -> String?)?,
                               imported: PortableBackup?,
                               onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (AccountHandle, PortableBackup?) {
        enrollPortableCalls.append((accountId, identity, devicePath))
        onStep.map { report in [PortableEnrollmentStep.creatingCredential].forEach(report) }
        if let closure = enrollPortableClosure {
            return try closure(accountId, identity, devicePath, askPIN, imported)
        }
        return (AccountHandle.portableFixture(id: accountId, identity: identity, devicePath: devicePath), nil)
    }

    public func exportBackup(_ handle: AccountHandle,
                             pinProvider: (@Sendable () -> String?)?) throws -> PortableBackup {
        exportCalls.append(handle)
        if let closure = exportClosure {
            return try closure(handle, pinProvider)
        }
        return PortableBackup(masterKey: Data(repeating: 0x00, count: PortableBackup.masterKeyByteCount),
                              identity: handle.account.identity)!
    }
}

public final class MockMigrationService: Migrating, @unchecked Sendable {
    public init() {}

    public var migrateClosure: ((AccountHandle, AccountIdentity, (@Sendable () -> String?)?) throws -> AccountHandle)?
    public private(set) var migrateCalls: [(AccountHandle, AccountIdentity)] = []
    public var finishClosure: ((AccountHandle, AccountHandle, (@Sendable () -> String?)?) throws -> AccountHandle)?
    public private(set) var finishCalls: [(AccountHandle, AccountHandle)] = []
    public private(set) var discardCalls: [AccountHandle] = []

    public func migrate(_ old: AccountHandle,
                        identity: AccountIdentity,
                        askPIN: (@Sendable () -> String?)?,
                        onStep: (@Sendable (MigrationStep) -> Void)?) throws -> AccountHandle {
        migrateCalls.append((old, identity))
        if let closure = migrateClosure {
            return try closure(old, identity, askPIN)
        }
        return AccountHandle.portableFixture(id: old.id, identity: identity, devicePath: old.devicePath)
    }

    public func finishMigration(old: AccountHandle,
                                copy: AccountHandle,
                                askPIN: (@Sendable () -> String?)?,
                                onStep: (@Sendable (MigrationStep) -> Void)?) throws -> AccountHandle {
        finishCalls.append((old, copy))
        if let closure = finishClosure {
            return try closure(old, copy, askPIN)
        }
        return copy
    }

    public func discardMigrationCopy(_ copy: AccountHandle, pin: String?) throws {
        discardCalls.append(copy)
    }
}

public final class MockSecretDerivationService: SecretDeriving, @unchecked Sendable {
    public init() {}

    public var deriveSecretClosure: ((AccountHandle, String, Int, (@Sendable () -> String?)?) throws -> Data)?
    public private(set) var deriveSecretCalls: [(AccountHandle, String, Int)] = []

    public var deriveFixedClosure: ((AccountHandle, (@Sendable () -> String?)?) throws -> Data)?
    public private(set) var deriveFixedCalls: [AccountHandle] = []

    public var deriveMessageSecretClosure: ((AccountHandle, Data, (@Sendable () -> String?)?) throws -> Data)?
    public private(set) var deriveMessageSecretCalls: [(AccountHandle, Data)] = []

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

    public func deriveMessageSecret(_ handle: AccountHandle,
                                    nonce: Data,
                                    pinProvider: (@Sendable () -> String?)?) throws -> Data {
        deriveMessageSecretCalls.append((handle, nonce))
        if let closure = deriveMessageSecretClosure {
            return try closure(handle, nonce, pinProvider)
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
    /// A v1 account, the released layout: the identity derived for a local one, the mask
    /// from `portable` for a portable one — and a portable one without material reads as
    /// unusable, which is what the key would report.
    static func fixture(id: String = "account",
                        kind: AccountKind = .local,
                        credentialId: Data? = nil,
                        portable: PortablePayload? = nil) -> Account {
        let credential = credentialId ?? Data(id.utf8)
        switch kind {
        case .local:
            return Account(id: id,
                           kind: .local,
                           format: .v1,
                           credentialIdB64: credential.base64EncodedString(),
                           identity: .derived(fromCredentialId: credential))
        case .portable:
            return Account(id: id,
                           kind: .portable,
                           format: .v1,
                           credentialIdB64: credential.base64EncodedString(),
                           identity: nil,
                           mask: portable?.external,
                           integrity: portable == nil ? .recordCorrupt : .ok)
        }
    }

    /// The mask every fixture portable account carries, unless a test brings its own.
    static let fixtureMask = Data((0..<AccountRecord.maskByteCount).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 7) })

    /// The identity a fixture is given when the test does not care which: a fixed function
    /// of the id, so two fixtures with one id agree and two with different ids differ.
    static func fixtureIdentity(for id: String) -> AccountIdentity {
        AccountIdentity.derived(fromCredentialId: Data("identity:\(id)".utf8))
    }

    /// A v2 account of either kind, with its record read: a portable one carries the mask.
    static func v2Fixture(id: String = "account",
                          kind: AccountKind = .local,
                          credentialId: Data? = nil,
                          identity: AccountIdentity? = nil,
                          mask: Data? = nil,
                          integrity: AccountIntegrity = .ok) -> Account {
        Account(id: id,
                kind: kind,
                format: .v2,
                credentialIdB64: (credentialId ?? Data(id.utf8)).base64EncodedString(),
                identity: identity ?? fixtureIdentity(for: id),
                mask: kind == .portable ? (mask ?? fixtureMask) : nil,
                integrity: integrity)
    }

    /// A portable account with key material on it — v2, the way this version writes one,
    /// with an identity (a fixed one derived from the id, unless given); or with
    /// `legacy: true` the way released versions wrote it: v1, material only, needing
    /// migration.
    static func portableFixture(id: String = "vault",
                                credentialId: Data? = nil,
                                identity: AccountIdentity? = nil,
                                legacy: Bool = false) -> Account {
        if legacy {
            return fixture(id: id, kind: .portable, credentialId: credentialId, portable: PortablePayload(external: fixtureMask))
        }
        return v2Fixture(id: id, kind: .portable, credentialId: credentialId, identity: identity)
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

    static func v2Fixture(id: String = "account",
                          kind: AccountKind = .local,
                          credentialId: Data? = nil,
                          identity: AccountIdentity? = nil,
                          mask: Data? = nil,
                          devicePath: String = "/dev/mock",
                          integrity: AccountIntegrity = .ok) -> AccountHandle {
        AccountHandle(account: .v2Fixture(id: id, kind: kind, credentialId: credentialId, identity: identity, mask: mask, integrity: integrity),
                      devicePath: devicePath)
    }

    static func portableFixture(id: String = "vault",
                                credentialId: Data? = nil,
                                identity: AccountIdentity? = nil,
                                legacy: Bool = false,
                                devicePath: String = "/dev/mock") -> AccountHandle {
        AccountHandle(account: .portableFixture(id: id, credentialId: credentialId, identity: identity, legacy: legacy),
                      devicePath: devicePath)
    }
}
