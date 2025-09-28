import XCTest
import FidoPassCore
@testable import FidoPassApp
import TestSupport

@MainActor
final class AccountsViewModelPasswordsTests: XCTestCase {
    func testGeneratePasswordSuccessUpdatesState() throws {
        let device = FidoDevice(path: "/dev/key",
                                product: "Key",
                                manufacturer: "Vendor",
                                vendorId: 1,
                                productId: 2)

        let passwordGenerator = MockPasswordGenerator()
        let generateExpectation = expectation(description: "password generated")
        passwordGenerator.generateClosure = { account, label, override, requireUV, pinProvider in
            XCTAssertEqual(account.id, "acct")
            XCTAssertEqual(label, "label")
            XCTAssertTrue(requireUV)
            XCTAssertEqual(pinProvider?(), "1234")
            generateExpectation.fulfill()
            return "secret"
        }

        let core = FidoPassCore(deviceRepository: MockDeviceRepository(),
                                enrollmentService: MockEnrollmentService(),
                                portableEnrollmentService: MockPortableEnrollmentService(),
                                secretDerivationService: MockSecretDerivationService(),
                                passwordGenerator: passwordGenerator)

        let vault = SecurePinVault(defaultTTL: 60)
        let token = vault.store(pin: "1234", ttl: 60)

        let suite = "PasswordSuccess-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let vm = AccountsViewModel(core: core,
                                   pinVault: vault,
                                   pinTTL: 60,
                                   deviceWorkQueue: DispatchQueue(label: "test.deviceWork"),
                                   ubiStore: InMemoryUbiquitousStore(),
                                   userDefaults: defaults,
                                   notificationCenter: NotificationCenter(),
                                   enableDeviceMonitors: false)

        vm.deviceStates[device.path] = AccountsViewModel.DeviceState(device: device,
                                                                     unlocked: true,
                                                                     pinToken: token,
                                                                     pinDraft: "")
        let account = Account.fixture(id: "acct", devicePath: device.path)
        vm.generatePassword(for: account, label: "label")

        wait(for: [generateExpectation], timeout: 1.0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(vm.generatedPassword, "secret")
        XCTAssertEqual(vm.toastMessage?.title, "Password generated")
        XCTAssertFalse(vm.generating)
        XCTAssertNil(vm.generatingAccountId)
    }

    func testGeneratePasswordPropagatesError() throws {
        let device = FidoDevice(path: "/dev/key",
                                product: "Key",
                                manufacturer: "Vendor",
                                vendorId: 1,
                                productId: 2)

        let passwordGenerator = MockPasswordGenerator()
        let generateExpectation = expectation(description: "password attempt")
        passwordGenerator.generateClosure = { _, _, _, _, _ in
            generateExpectation.fulfill()
            throw TestError.generic("failure")
        }

        let core = FidoPassCore(deviceRepository: MockDeviceRepository(),
                                enrollmentService: MockEnrollmentService(),
                                portableEnrollmentService: MockPortableEnrollmentService(),
                                secretDerivationService: MockSecretDerivationService(),
                                passwordGenerator: passwordGenerator)

        let vault = SecurePinVault(defaultTTL: 60)
        let token = vault.store(pin: "0000", ttl: 60)

        let suite = "PasswordError-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let vm = AccountsViewModel(core: core,
                                   pinVault: vault,
                                   pinTTL: 60,
                                   deviceWorkQueue: DispatchQueue(label: "test.deviceWork"),
                                   ubiStore: InMemoryUbiquitousStore(),
                                   userDefaults: defaults,
                                   notificationCenter: NotificationCenter(),
                                   enableDeviceMonitors: false)

        vm.deviceStates[device.path] = AccountsViewModel.DeviceState(device: device,
                                                                     unlocked: true,
                                                                     pinToken: token,
                                                                     pinDraft: "")
        let account = Account.fixture(id: "acct", devicePath: device.path)
        vm.generatePassword(for: account, label: "label")

        wait(for: [generateExpectation], timeout: 1.0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(vm.errorMessage, TestError.generic("failure").localizedDescription)
        XCTAssertFalse(vm.generating)
        XCTAssertNil(vm.generatedPassword)
    }
}
