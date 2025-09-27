import Foundation

public final class FidoPassCore {
    public static let shared = FidoPassCore()

    private let deviceRepository: DeviceRepositoryProtocol
    private let enrollmentService: EnrollmentServiceProtocol
    private let portableEnrollmentService: PortableEnrollmentServiceProtocol
    private let passwordGenerator: PasswordGenerating

    public init(deviceRepository: DeviceRepositoryProtocol? = nil,
                enrollmentService: EnrollmentServiceProtocol? = nil,
                portableEnrollmentService: PortableEnrollmentServiceProtocol? = nil,
                secretDerivationService: SecretDerivationServiceProtocol? = nil,
                passwordGenerator: PasswordGenerating? = nil) {
        Libfido2Context.initialize()

        let resolvedDeviceRepository = deviceRepository ?? DeviceRepository()
        self.deviceRepository = resolvedDeviceRepository

        let resolvedEnrollment = enrollmentService ?? EnrollmentService(deviceRepository: resolvedDeviceRepository)
        self.enrollmentService = resolvedEnrollment

        let hmacSecretService = HmacSecretService(deviceRepository: resolvedDeviceRepository)
        let resolvedSecretDerivation = secretDerivationService ?? SecretDerivationService(hmacSecretService: hmacSecretService)

        let resolvedPortable = portableEnrollmentService ?? PortableEnrollmentService(enrollmentService: resolvedEnrollment,
                                                                                       secretDerivationService: resolvedSecretDerivation)
        self.portableEnrollmentService = resolvedPortable

        let resolvedPasswordGenerator = passwordGenerator ?? PasswordGenerator(secretDerivationService: resolvedSecretDerivation)
        self.passwordGenerator = resolvedPasswordGenerator
    }

    public func listDevices(limit: Int = 16) throws -> [FidoDevice] {
        try deviceRepository.listDevices(limit: limit)
    }

    public func enroll(accountId: String,
                       rpId: String = "fidopass.local",
                       userName: String = "",
                       requireUV: Bool = true,
                       residentKey: Bool = true,
                       devicePath: String? = nil,
                       askPIN: (() -> String?)? = nil) throws -> Account {
        try enrollmentService.enroll(accountId: accountId,
                                     rpId: rpId,
                                     userName: userName,
                                     requireUV: requireUV,
                                     residentKey: residentKey,
                                     devicePath: devicePath,
                                     askPIN: askPIN)
    }

    public func enrollPortable(accountId: String,
                               requireUV: Bool = true,
                               devicePath: String? = nil,
                               askPIN: (() -> String?)? = nil,
                               importedKeyB64: String?) throws -> (Account, String?) {
        try portableEnrollmentService.enrollPortable(accountId: accountId,
                                                     requireUV: requireUV,
                                                     devicePath: devicePath,
                                                     askPIN: askPIN,
                                                     importedKeyB64: importedKeyB64)
    }

    public func generatePassword(account: Account,
                                 label: String,
                                 policy override: PasswordPolicy? = nil,
                                 requireUV: Bool = true,
                                 pinProvider: (() -> String?)? = nil) throws -> String {
        try passwordGenerator.generatePassword(account: account,
                                               label: label,
                                               policy: override,
                                               requireUV: requireUV,
                                               pinProvider: pinProvider)
    }

    public func enumerateAccounts(rpId: String = "fidopass.local",
                                  devicePath: String,
                                  pin: String?) throws -> [Account] {
        try enrollmentService.enumerateAccounts(rpId: rpId,
                                                devicePath: devicePath,
                                                pin: pin)
    }

    public func exportImportedKey(_ account: Account,
                                  requireUV: Bool = true,
                                  pinProvider: (() -> String?)? = nil) throws -> String {
        try portableEnrollmentService.exportImportedKey(account,
                                                        requireUV: requireUV,
                                                        pinProvider: pinProvider)
    }

    public func deleteAccount(_ account: Account, pin: String?) throws {
        try enrollmentService.deleteAccount(account, pin: pin)
    }
}
