import FidoPassCore
import Foundation

/// What the manager window has read from each key.
///
/// A separate store from `DeviceStore` and `AccountStore` for the usual reason: this is read
/// rarely, is large, and nothing in the HUD depends on it. Keeping it here means opening the
/// manager cannot redraw the panel, and closing it drops the whole thing.
///
/// **Nothing is read until asked.** Opening a key on macOS seizes it away from every other
/// process, so a window that read on appear would make `ykman` unusable for as long as it
/// was open. Every method here runs from a button.
@MainActor
final class InventoryStore: ObservableObject {

    /// One key's reading. The two halves are tracked apart because they cost different
    /// things: the self-description needs only an open, the credential list needs the PIN.
    /// A key whose PIN has expired must still show what it already said about itself.
    struct Reading: Equatable {
        var info: AuthenticatorInfo?
        var inventory: CredentialInventory?
        var infoError: PresentedError?
        var inventoryError: PresentedError?
        var isReading = false
        /// True when the credential list was not read because the key is locked, as opposed
        /// to having failed. The difference decides whether the UI offers "unlock" or "retry".
        var needsUnlock = false

        var hasAnything: Bool { info != nil || inventory != nil }
    }

    @Published private(set) var readings: [String: Reading] = [:]

    private let worker: KeyWorker
    private let pinFor: (String) -> String?

    init(worker: KeyWorker, pin: @escaping (String) -> String?) {
        self.worker = worker
        self.pinFor = pin
    }

    func reading(for path: String) -> Reading { readings[path] ?? Reading() }

    // MARK: - Reading

    /// Reads what the key says about itself, and — when the key is unlocked — its credentials.
    ///
    /// Both in one call because that is what the "Read key" button means. The credential half
    /// is skipped rather than failed when the key is locked: asking for a PIN the store does
    /// not have would mean a second place in the app that can spend a PIN attempt.
    func read(_ device: FidoDevice) async {
        let path = device.path
        var reading = self.reading(for: path)
        reading.isReading = true
        reading.infoError = nil
        reading.inventoryError = nil
        readings[path] = reading

        do {
            reading.info = try await worker.device { try $0.inspect(devicePath: path) }
        } catch {
            reading.infoError = PresentedError(error)
        }

        if let pin = pinFor(path) {
            reading.needsUnlock = false
            do {
                reading.inventory = try await worker.device { try $0.inventory(devicePath: path, pin: pin) }
            } catch {
                reading.inventoryError = PresentedError(error)
            }
        } else {
            // Not an error: the key simply has not been unlocked in this session.
            reading.needsUnlock = true
            reading.inventory = nil
        }

        reading.isReading = false
        readings[path] = reading
    }

    /// Re-reads only the credential list. Used after the key has been unlocked, so the
    /// self-description already on screen is not thrown away and re-fetched.
    func readInventory(_ device: FidoDevice) async {
        let path = device.path
        guard let pin = pinFor(path) else {
            var reading = self.reading(for: path)
            reading.needsUnlock = true
            readings[path] = reading
            return
        }

        var reading = self.reading(for: path)
        reading.isReading = true
        reading.inventoryError = nil
        // Cleared before the attempt, not after it succeeds. A key that *is* open and then
        // fails for some other reason must report that reason; leaving the flag set made a
        // real failure render as "locked", which is both wrong and unactionable.
        reading.needsUnlock = false
        readings[path] = reading

        do {
            reading.inventory = try await worker.device { try $0.inventory(devicePath: path, pin: pin) }
        } catch {
            reading.inventoryError = PresentedError(error)
        }
        reading.isReading = false
        readings[path] = reading
    }

    /// Finishes a read that stopped for want of a PIN.
    ///
    /// Called when a key becomes unlocked. It is not a fresh request — it completes the one
    /// the user already made by pressing "Read key" and was told needed an unlock — so it
    /// fires only for a key that has been read once and is still waiting. A key nobody asked
    /// about stays untouched, which is the rule the whole store is built around.
    func resumeAfterUnlock(_ device: FidoDevice) async {
        let reading = self.reading(for: device.path)
        guard reading.hasAnything, reading.needsUnlock else { return }
        await readInventory(device)
    }

    /// Re-reads only the self-description. Used after a setting is changed, so the switch on
    /// screen shows what the key now says rather than what the app hoped it would say.
    func refreshInfo(_ device: FidoDevice) async {
        let path = device.path
        var reading = self.reading(for: path)
        reading.isReading = true
        readings[path] = reading
        do {
            reading.info = try await worker.device { try $0.inspect(devicePath: path) }
            reading.infoError = nil
        } catch {
            reading.infoError = PresentedError(error)
        }
        reading.isReading = false
        readings[path] = reading
    }

    // MARK: - Forgetting

    /// Drops the credential list of a key that is no longer unlocked, keeping what it said
    /// about itself.
    ///
    /// The list carries user names of other services — the very thing a session lock is
    /// supposed to put away — while the self-description is public information about the
    /// model and reveals nothing about its owner.
    func dropInventory(devicePath: String) {
        guard var reading = readings[devicePath], reading.inventory != nil || !reading.needsUnlock else { return }
        reading.inventory = nil
        reading.inventoryError = nil
        reading.needsUnlock = true
        readings[devicePath] = reading
    }

    /// Forgets a key entirely — it was unplugged, or the machine locked.
    func drop(devicePath: String) {
        readings.removeValue(forKey: devicePath)
    }

    func dropAll() {
        readings.removeAll()
    }
}
