import XCTest
import FidoPassCore
@testable import FidoPassApp
import TestSupport

final class AccountsViewModelPasswordsTests: XCTestCase {
    @MainActor
    func testGeneratePasswordSuccessUpdatesState() async throws {
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

        let vmContext = makeViewModel(passwordGenerator: passwordGenerator,
                                      pin: "1234",
                                      device: device)
        let vm = vmContext.viewModel
        let account = Account.fixture(id: "acct", devicePath: device.path)

        vm.deviceStates[device.path] = vmContext.deviceState
        vm.generatePassword(for: account, label: "label")

        await fulfillment(of: [generateExpectation], timeout: 2.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        let generated = vm.generatedPassword
        let toastTitle = vm.toastMessage?.title
        let generating = vm.generating
        let generatingAccountId = vm.generatingAccountId

        XCTAssertEqual(generated, "secret")
        XCTAssertEqual(toastTitle, "Password generated")
        XCTAssertFalse(generating)
        XCTAssertNil(generatingAccountId)
    }

    @MainActor
    func testGeneratePasswordPropagatesError() async throws {
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

        let vmContext = makeViewModel(passwordGenerator: passwordGenerator,
                                      pin: "0000",
                                      device: device)
        let vm = vmContext.viewModel
        let account = Account.fixture(id: "acct", devicePath: device.path)

        vm.deviceStates[device.path] = vmContext.deviceState
        vm.generatePassword(for: account, label: "label")

        await fulfillment(of: [generateExpectation], timeout: 2.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        let errorMessage = vm.errorMessage
        let generating = vm.generating
        let generatedPassword = vm.generatedPassword

        XCTAssertEqual(errorMessage, TestError.generic("failure").localizedDescription)
        XCTAssertFalse(generating)
        XCTAssertNil(generatedPassword)
    }

    @MainActor
    private func makeViewModel(passwordGenerator: MockPasswordGenerator,
                               pin: String,
                               device: FidoDevice) -> (viewModel: AccountsViewModel, deviceState: AccountsViewModel.DeviceState) {
        let core = FidoPassCore(deviceRepository: MockDeviceRepository(),
                                enrollmentService: MockEnrollmentService(),
                                portableEnrollmentService: MockPortableEnrollmentService(),
                                secretDerivationService: MockSecretDerivationService(),
                                passwordGenerator: passwordGenerator)
        let vault = SecurePinVault(defaultTTL: 60)
        let token = vault.store(pin: pin, ttl: 60)

        let suite = "PasswordTests-\(UUID().uuidString)"
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

        let state = AccountsViewModel.DeviceState(device: device,
                                                  unlocked: true,
                                                  pinToken: token,
                                                  pinDraft: "")
        return (vm, state)
    }
}
