import XCTest
import FidoPassCore
@testable import FidoPassApp
import TestSupport

final class AccountsViewModelReloadTests: XCTestCase {
    @MainActor
    func testReloadPopulatesDevicesAndAccounts() async throws {
        let device = FidoDevice(path: "/dev/key",
                                product: "Key",
                                manufacturer: "Vendor",
                                vendorId: 1,
                                productId: 2)

        let deviceRepository = MockDeviceRepository()
        deviceRepository.devices = [device]

        let enrollment = MockEnrollmentService()
        enrollment.enumerateClosure = { rpId, devicePath, _ in
            switch rpId {
            case "fidopass.local":
                return [
                    Account.fixture(id: "acct1", rpId: rpId, userName: "user1", devicePath: devicePath),
                    Account.fixture(id: "acct2", rpId: rpId, userName: "user2", devicePath: devicePath)
                ]
            case "fidopass.portable":
                return [Account.fixture(id: "portable", rpId: rpId, userName: "payload", devicePath: devicePath)]
            default:
                return []
            }
        }

        let portable = MockPortableEnrollmentService()
        let context = makeViewModel(deviceRepository: deviceRepository,
                                    enrollment: enrollment,
                                    portable: portable,
                                    device: device)
        let vm = context.viewModel

        vm.deviceStates[device.path] = context.deviceState
        vm.selectedDevicePath = device.path
        vm.reload()

        try await Task.sleep(nanoseconds: 500_000_000)

        let devices = vm.devices
        let accounts = vm.accounts.map { $0.id }
        let selected = vm.selected?.id
        let reloading = vm.reloading

        XCTAssertEqual(devices, [device])
        XCTAssertEqual(accounts, ["acct1", "acct2", "portable"])
        XCTAssertEqual(selected, "acct1")
        XCTAssertFalse(reloading)
    }

    @MainActor
    private func makeViewModel(deviceRepository: MockDeviceRepository,
                               enrollment: MockEnrollmentService,
                               portable: MockPortableEnrollmentService,
                               device: FidoDevice) -> (viewModel: AccountsViewModel, deviceState: AccountsViewModel.DeviceState) {
        let core = FidoPassCore(deviceRepository: deviceRepository,
                                enrollmentService: enrollment,
                                portableEnrollmentService: portable,
                                secretDerivationService: MockSecretDerivationService(),
                                passwordGenerator: MockPasswordGenerator())
        let vault = SecurePinVault(defaultTTL: 60)
        let token = vault.store(pin: "1234", ttl: 60)

        let queue = DispatchQueue(label: "test.deviceWork", qos: .userInitiated, attributes: .concurrent)
        let suiteName = "ReloadTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let vm = AccountsViewModel(core: core,
                                   pinVault: vault,
                                   pinTTL: 60,
                                   deviceWorkQueue: queue,
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
