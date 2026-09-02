import Foundation

public final class FidoPassCore: Sendable {
    public static let shared = FidoPassCore()

    private let deviceRepository: DeviceAccessing
    private let deviceLister: DeviceListing
    private let enrollmentService: Enrolling
    private let portableEnrollmentService: PortableEnrolling
    private let passwordGenerator: PasswordGenerating
    private let secretEncryption: SecretEncrypting
    private let deviceManagement: DeviceManaging
    private let inspection: AuthenticatorInspecting
    private let configuration: DeviceConfiguring

    public convenience init(deviceLister: DeviceListing? = nil,
                            enrollmentService: Enrolling? = nil,
                            portableEnrollmentService: PortableEnrolling? = nil,
                            secretDerivationService: SecretDeriving? = nil,
                            passwordGenerator: PasswordGenerating? = nil,
                            secretEncryption: SecretEncrypting? = nil,
                            deviceManagement: DeviceManaging? = nil,
                            inspection: AuthenticatorInspecting? = nil,
                            configuration: DeviceConfiguring? = nil) {
        self.init(deviceRepository: DeviceRepository(),
                  deviceLister: deviceLister,
                  enrollmentService: enrollmentService,
                  portableEnrollmentService: portableEnrollmentService,
                  secretDerivationService: secretDerivationService,
                  passwordGenerator: passwordGenerator,
                  secretEncryption: secretEncryption,
                  deviceManagement: deviceManagement,
                  inspection: inspection,
                  configuration: configuration)
    }

    /// The designated initialiser, with the device repository itself substitutable. Internal:
    /// the repository hands out raw libfido2 handles, which never cross the module boundary.
    init(deviceRepository resolvedDeviceRepository: DeviceAccessing,
         deviceLister: DeviceListing? = nil,
         enrollmentService: Enrolling? = nil,
         portableEnrollmentService: PortableEnrolling? = nil,
         secretDerivationService: SecretDeriving? = nil,
         passwordGenerator: PasswordGenerating? = nil,
         secretEncryption: SecretEncrypting? = nil,
         deviceManagement: DeviceManaging? = nil,
         inspection: AuthenticatorInspecting? = nil,
         configuration: DeviceConfiguring? = nil) {
        Libfido2Context.initialize()

        self.deviceRepository = resolvedDeviceRepository
        self.deviceLister = deviceLister ?? resolvedDeviceRepository

        let resolvedEnrollment = enrollmentService ?? EnrollmentService(deviceRepository: resolvedDeviceRepository)
        self.enrollmentService = resolvedEnrollment

        let hmacSecretService = HmacSecretService(deviceRepository: resolvedDeviceRepository)
        let resolvedSecretDerivation = secretDerivationService ?? SecretDerivationService(hmacSecretService: hmacSecretService)

        let resolvedPortable = portableEnrollmentService ?? PortableEnrollmentService(enrollmentService: resolvedEnrollment,
                                                                                       secretDerivationService: resolvedSecretDerivation)
        self.portableEnrollmentService = resolvedPortable

        let resolvedPasswordGenerator = passwordGenerator ?? PasswordGenerator(secretDerivationService: resolvedSecretDerivation)
        self.passwordGenerator = resolvedPasswordGenerator

        self.secretEncryption = secretEncryption ?? SecretEncryptionService(secretDerivationService: resolvedSecretDerivation)
        self.deviceManagement = deviceManagement ?? DeviceManagementService(deviceRepository: resolvedDeviceRepository)
        self.inspection = inspection ?? AuthenticatorInspectionService(deviceRepository: resolvedDeviceRepository)
        self.configuration = configuration ?? DeviceConfigurationService(deviceRepository: resolvedDeviceRepository)
    }

    public func listDevices() throws -> [FidoDevice] {
        try deviceLister.listDevices()
    }

    /// Reads authenticator state that needs no user interaction: PIN attempts left,
    /// whether a PIN exists, hmac-secret support and free credential slots.
    public func status(devicePath: String) throws -> DeviceStatus {
        try deviceRepository.status(devicePath: devicePath)
    }


    // MARK: - Inspection

    /// Everything the key reports about itself. No PIN and no touch — but it does open the
    /// device, so only ever call it because the user asked to look.
    public func inspect(devicePath: String) throws -> AuthenticatorInfo {
        try inspection.inspect(devicePath: devicePath)
    }

    /// Every resident credential on the key, of every relying party — not just FidoPass's.
    /// Needs the PIN, needs no touch.
    public func inventory(devicePath: String, pin: String) throws -> CredentialInventory {
        try inspection.inventory(devicePath: devicePath, pin: pin)
    }

    // MARK: - Authenticator settings

    /// Flips `alwaysUv` and returns the state the key reports afterwards. Reversible.
    @discardableResult
    public func toggleAlwaysUV(devicePath: String, pin: String) throws -> Bool {
        try configuration.toggleAlwaysUV(devicePath: devicePath, pin: pin)
    }

    /// Raises the shortest PIN the key accepts. **Cannot be undone or lowered.**
    public func setMinimumPINLength(devicePath: String, length: Int, pin: String) throws {
        try configuration.setMinimumPINLength(devicePath: devicePath, length: length, pin: pin)
    }

    /// Makes the key demand a new PIN before anything else works.
    public func forcePINChange(devicePath: String, pin: String) throws {
        try configuration.forcePINChange(devicePath: devicePath, pin: pin)
    }

    /// Turns on enterprise attestation. **Cannot be undone.**
    public func enableEnterpriseAttestation(devicePath: String, pin: String) throws {
        try configuration.enableEnterpriseAttestation(devicePath: devicePath, pin: pin)
    }

    /// Creates a local account: one resident credential, one touch.
    public func enroll(accountId: String,
                       kind: AccountKind = .local,
                       devicePath: String,
                       askPIN: (@Sendable () -> String?)? = nil) throws -> AccountHandle {
        try enrollmentService.enroll(accountId: accountId,
                                     kind: kind,
                                     devicePath: devicePath,
                                     askPIN: askPIN)
    }

    /// Creates a portable account: two touches, and — when the key material is fresh rather
    /// than imported — a backup to show the user once.
    public func enrollPortable(accountId: String,
                               devicePath: String,
                               askPIN: (@Sendable () -> String?)? = nil,
                               imported: PortableBackup?,
                               onStep: (@Sendable (PortableEnrollmentStep) -> Void)? = nil) throws -> (AccountHandle, PortableBackup?) {
        try portableEnrollmentService.enrollPortable(accountId: accountId,
                                                     devicePath: devicePath,
                                                     askPIN: askPIN,
                                                     imported: imported,
                                                     onStep: onStep)
    }

    /// Derives the password for `label`. One touch.
    ///
    /// `parameters` is `.v1` for every account until the key can store them per account;
    /// passing anything else derives a different password, which is the point of the type.
    public func generatePassword(_ handle: AccountHandle,
                                 label: String,
                                 parameters: DerivationParameters = .v1,
                                 pinProvider: (@Sendable () -> String?)? = nil) throws -> String {
        try passwordGenerator.generatePassword(handle,
                                               label: label,
                                               parameters: parameters,
                                               pinProvider: pinProvider)
    }

    public func enumerateAccounts(kind: AccountKind = .local,
                                  devicePath: String,
                                  pin: String?) throws -> [AccountHandle] {
        try enrollmentService.enumerateAccounts(rpId: kind.rpId,
                                                devicePath: devicePath,
                                                pin: pin)
    }

    /// The account's backup — master key and identity. One touch.
    public func exportBackup(_ handle: AccountHandle,
                             pinProvider: (@Sendable () -> String?)? = nil) throws -> PortableBackup {
        try portableEnrollmentService.exportBackup(handle, pinProvider: pinProvider)
    }

    /// Gives a portable account written before identities existed one. PIN, no touch, and
    /// no change to any password: the identity is not an input to derivation.
    public func assignIdentity(_ handle: AccountHandle,
                               identity: AccountIdentity,
                               pinProvider: (@Sendable () -> String?)? = nil) throws -> AccountHandle {
        try portableEnrollmentService.assignIdentity(handle, identity: identity, pinProvider: pinProvider)
    }

    /// Derives the key used by the text editor. Costs one touch of the authenticator.
    public func deriveEncryptionKey(_ handle: AccountHandle,
                                    label: String,
                                    parameters: DerivationParameters = .v1,
                                    pinProvider: (@Sendable () -> String?)? = nil) throws -> EncryptionKey {
        try secretEncryption.deriveEncryptionKey(handle,
                                                 label: label,
                                                 parameters: parameters,
                                                 pinProvider: pinProvider)
    }

    /// Seals and opens text under a derived key, without the rest of the facade.
    public var cipher: SecretCipher { secretEncryption }

    public func seal(_ plaintext: String, with key: EncryptionKey) throws -> String {
        try secretEncryption.seal(plaintext, with: key)
    }

    public func open(_ envelopeB64: String, with key: EncryptionKey) throws -> String {
        try secretEncryption.open(envelopeB64, with: key)
    }

    public func deleteAccount(_ handle: AccountHandle, pin: String?) throws {
        try enrollmentService.deleteAccount(handle, pin: pin)
    }

    // MARK: - Key management

    /// Gives a key that has none its first PIN. Nothing on the key can be used without one.
    public func setInitialPIN(devicePath: String, newPIN: String) throws {
        try deviceManagement.setInitialPIN(devicePath: devicePath, newPIN: newPIN)
    }

    /// Replaces the PIN. Derived passwords are unaffected — the PIN opens the key, it is not
    /// an input to the derivation.
    public func changePIN(devicePath: String, oldPIN: String, newPIN: String) throws {
        try deviceManagement.changePIN(devicePath: devicePath, oldPIN: oldPIN, newPIN: newPIN)
    }

    /// Erases every credential on the key and its PIN. There is no way back from this.
    public func resetDevice(devicePath: String,
                            expectedAAGUID: String? = nil,
                            timeout: Duration = .seconds(35)) throws {
        try deviceManagement.reset(devicePath: devicePath,
                                   expectedAAGUID: expectedAAGUID,
                                   timeout: timeout)
    }
}
