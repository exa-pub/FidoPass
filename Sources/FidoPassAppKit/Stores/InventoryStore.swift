import FidoPassCore
import Foundation

/// Caches manager reads. Hardware access runs only for explicit user requests.
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

    var onAuthenticationFailure: ((String) -> Void)?
    private var lifetimes: [String: OperationLease] = [:]
    private func begin(_ path: String) -> OperationLease {
        lifetimes.removeValue(forKey: path)?.invalidate()
        let token = OperationLease()
        lifetimes[path] = token
        return token
    }
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
        let token = begin(path)
        var reading = self.reading(for: path)
        reading.isReading = true
        reading.infoError = nil
        reading.inventoryError = nil
        readings[path] = reading

        do {
            reading.info = try await worker.device(validity: token) { try $0.inspect(devicePath: path) }
        } catch {
            reading.infoError = PresentedError(error)
        }

        guard token.isValid, KeyOperationContext.lease?.isValid != false else { return }
        if let pin = pinFor(path) {
            reading.needsUnlock = false
            do {
                reading.inventory = try await worker.device(validity: token) { try $0.inventory(devicePath: path, pin: pin) }
            } catch {
                if token.isValid, KeyFailurePolicy.invalidatesPINSession(error) { onAuthenticationFailure?(path) }
                reading.inventoryError = PresentedError(error)
            }
        } else {
            // Not an error: the key simply has not been unlocked in this session.
            reading.needsUnlock = true
            reading.inventory = nil
        }

        guard token.isValid, KeyOperationContext.lease?.isValid != false else { return }
        reading.isReading = false
        readings[path] = reading
    }

    /// Re-reads only the credential list. Used after the key has been unlocked, so the
    /// self-description already on screen is not thrown away and re-fetched.
    func readInventory(_ device: FidoDevice) async {
        let path = device.path
        let token = begin(path)
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
            reading.inventory = try await worker.device(validity: token) { try $0.inventory(devicePath: path, pin: pin) }
        } catch {
            if token.isValid, KeyFailurePolicy.invalidatesPINSession(error) { onAuthenticationFailure?(path) }
            reading.inventoryError = PresentedError(error)
        }
        guard token.isValid, KeyOperationContext.lease?.isValid != false else { return }
        reading.isReading = false
        readings[path] = reading
    }

    /// Completes an explicitly requested inventory read after its key is unlocked.
    func resumeAfterUnlock(_ device: FidoDevice) async {
        let reading = self.reading(for: device.path)
        guard reading.hasAnything, reading.needsUnlock else { return }
        await readInventory(device)
    }

    /// Re-reads only the self-description. Used after a setting is changed, so the switch on
    /// screen shows what the key now says rather than what the app hoped it would say.
    func refreshInfo(_ device: FidoDevice) async {
        let path = device.path
        let token = begin(path)
        var reading = self.reading(for: path)
        reading.isReading = true
        readings[path] = reading
        do {
            reading.info = try await worker.device(validity: token) { try $0.inspect(devicePath: path) }
            reading.infoError = nil
        } catch {
            reading.infoError = PresentedError(error)
        }
        guard token.isValid, KeyOperationContext.lease?.isValid != false else { return }
        reading.isReading = false
        readings[path] = reading
    }

    // MARK: - Forgetting

    /// Drops private credential metadata on lock, retaining public authenticator information.
    func dropInventory(devicePath: String) {
        lifetimes.removeValue(forKey: devicePath)?.invalidate()
        guard var reading = readings[devicePath], reading.inventory != nil || !reading.needsUnlock else { return }
        reading.isReading = false
        reading.inventory = nil
        reading.inventoryError = nil
        reading.needsUnlock = true
        readings[devicePath] = reading
    }

    /// Forgets a key entirely — it was unplugged, or the machine locked.
    func drop(devicePath: String) {
        lifetimes.removeValue(forKey: devicePath)?.invalidate()
        readings.removeValue(forKey: devicePath)
    }

    func dropAll() {
        for token in lifetimes.values { token.invalidate() }
        lifetimes.removeAll()
        readings.removeAll()
    }
}
