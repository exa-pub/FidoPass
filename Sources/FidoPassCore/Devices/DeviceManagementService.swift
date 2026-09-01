import Foundation
import CLibfido2

/// Setting, changing and clearing the key's own state.
///
/// Every method is one libfido2 call plus the handling around it. What is worth reading here
/// is the handling: the PIN wiping, and the timeout on reset.
final class DeviceManagementService: DeviceManaging, @unchecked Sendable {

    private let deviceRepository: DeviceRepositoryProtocol

    init(deviceRepository: DeviceRepositoryProtocol) {
        self.deviceRepository = deviceRepository
    }

    func setInitialPIN(devicePath: String, newPIN: String) throws {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            try PinScope.withPIN(newPIN) { pin in
                // A nil old PIN is what makes this "set" rather than "change". The two are
                // one C function and separate methods here on purpose: getting that argument
                // wrong means changing a PIN where one was meant to be created.
                try Libfido2Context.check(fido_dev_set_pin(device, pin, nil),
                                          operation: "dev_set_pin")
            }
        }
    }

    func changePIN(devicePath: String, oldPIN: String, newPIN: String) throws {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            // Nested rather than a two-argument helper: `PinScope` already guarantees the
            // heap copy is wiped, and the new PIN needs that guarantee exactly as much as the
            // old one does.
            try PinScope.withPIN(newPIN) { newPin in
                try PinScope.withPIN(oldPIN) { oldPin in
                    try Libfido2Context.check(fido_dev_set_pin(device, newPin, oldPin),
                                              operation: "dev_set_pin")
                }
            }
        }
    }

    func reset(devicePath: String, expectedAAGUID: String?, timeout: Duration) throws {
        try deviceRepository.withOpenedDevice(path: devicePath) { device, _ in
            if let expectedAAGUID, let actual = try deviceRepository.aaguid(of: device),
               actual != expectedAAGUID {
                throw FidoPassError.invalidState("This is a different security key from the one you started with. Nothing was erased.")
            }
            // Without this the call waits forever: libfido2 initialises `timeout_ms` to -1
            // (`src/dev.c`), and a reset nobody confirms would hold this worker thread for
            // the rest of the session. The app cannot cancel it either — `fido_dev_cancel`
            // is not surfaced — so the deadline has to be set before, not imposed after.
            let milliseconds = Int32(clamping: timeout.components.seconds * 1000)
            try Libfido2Context.check(fido_dev_set_timeout(device, milliseconds),
                                      operation: "dev_set_timeout")
            try Libfido2Context.check(fido_dev_reset(device), operation: "dev_reset")
        }
    }
}
