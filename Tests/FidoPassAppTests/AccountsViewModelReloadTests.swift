import XCTest
import FidoPassCore
@testable import FidoPassApp
import TestSupport

@MainActor
final class AccountsViewModelReloadTests: XCTestCase {
    func testReloadPopulatesDevicesAndAccounts() {
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
        let core = FidoPassCore(deviceRepository: deviceRepository,
                                enrollmentService: enrollment,
                                portableEnrollmentService: portable,
                                secretDerivationService: MockSecretDerivationService(),
                                passwordGenerator: MockPasswordGenerator())

        let vault = SecurePinVault(defaultTTL: 60)
        let token = vault.store(pin: "1234", ttl: 60)

        let queue = DispatchQueue(label: "test.deviceWork", qos: .userInitiated, attributes: .concurrent)
        let ubiStore = InMemoryUbiquitousStore()
        let suiteName = "ReloadTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let vm = AccountsViewModel(core: core,
                                   pinVault: vault,
                                   pinTTL: 60,
                                   deviceWorkQueue: queue,
                                   ubiStore: ubiStore,
                                   userDefaults: defaults,
                                   notificationCenter: NotificationCenter(),
                                   enableDeviceMonitors: false)

        vm.deviceStates[device.path] = AccountsViewModel.DeviceState(device: device,
                                                                     unlocked: true,
                                                                     pinToken: token,
                                                                     pinDraft: "")
        vm.selectedDevicePath = device.path

        vm.reload()
        vm.deviceWorkQueue.sync(flags: DispatchWorkItemFlags.barrier) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(vm.devices, [device])
        XCTAssertEqual(vm.accounts.map { $0.id }, ["acct1", "acct2", "portable"])
        XCTAssertEqual(vm.selected?.id, "acct1")
        XCTAssertFalse(vm.reloading)
    }
}
