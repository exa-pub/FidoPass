import Combine
import Foundation
import FidoPassCore

/// Owns the shared services, stores and cross-store reactions for one application.
@MainActor
final class AppContainer {

    let preferences: Preferences
    let devices: DeviceStore
    let accounts: AccountStore
    let generation: GenerationStore
    /// What the manager window has read. Empty until that window asks for something.
    let inventory: InventoryStore
    let labels: LabelStore
    let clipboard: ClipboardService
    let touchGate: TouchGate
    let decryptor: DecryptorCoordinator
    let router: WindowRouter
    let reset: ResetCoordinator
    let temporaryUV: TemporaryUVStore
    /// The menu-bar panel's store.
    let panel: PanelStore
    /// The manager window's store. Reads nothing until that window opens.
    let manager: ManagerStore

    private var subscriptions: Set<AnyCancellable> = []

    /// The stores are built here rather than injected as defaults: a default argument is
    /// evaluated outside the main actor, and every one of these is main-actor bound.
    init(backend: KeyBackend = LiveKeyBackend(),
         router: WindowRouter,
         preferences: Preferences? = nil,
         labels: LabelStore? = nil,
         clipboard: ClipboardService? = nil,
         temporaryUVDuration: Duration = .seconds(60),
         emptyConfirmationDelay: Duration = .milliseconds(700),
         enableMonitors: Bool = true,
         enableDeviceMonitor: Bool = true) {
        let settings = preferences ?? Preferences()
        // One worker for the whole app: a security key is exclusive, and serialising every
        // call through a single object is what keeps two windows from reaching for it at once.
        let worker = KeyWorker(backend: backend)
        let clipboard = clipboard ?? ClipboardService()
        let deviceStore = DeviceStore(worker: worker,
                                      pinTTL: settings.lockTimeout,
                                      emptyConfirmationDelay: emptyConfirmationDelay,
                                      enableMonitors: enableMonitors,
                                      enableDeviceMonitor: enableDeviceMonitor)
        let accountStore = AccountStore(worker: worker,
                                        pin: { [weak deviceStore] path in deviceStore?.pin(for: path) },
                                        pinProvider: { [weak deviceStore] path in deviceStore?.pinProvider(for: path) })
        let generationStore = GenerationStore(worker: worker,
                                              clipboard: clipboard,
                                              pinProvider: { [weak deviceStore] path in deviceStore?.pinProvider(for: path) })
        let inventoryStore = InventoryStore(worker: worker,
                                            pin: { [weak deviceStore] path in deviceStore?.pin(for: path) })
        let labelStore = labels ?? LabelStore()
        let touchGate = TouchGate()
        let temporaryUV = TemporaryUVStore(devices: deviceStore, gate: touchGate,
                                            duration: temporaryUVDuration)
        let decryptor = DecryptorCoordinator(router: router)
        let reset = ResetCoordinator(devices: deviceStore,
                                     accounts: accountStore,
                                     labels: labelStore,
                                     preferences: settings,
                                     touchGate: touchGate)

        self.preferences = settings
        self.devices = deviceStore
        self.accounts = accountStore
        self.generation = generationStore
        self.inventory = inventoryStore
        self.labels = labelStore
        self.clipboard = clipboard
        self.touchGate = touchGate
        self.temporaryUV = temporaryUV
        self.decryptor = decryptor
        self.router = router
        self.reset = reset
        self.manager = ManagerStore(devices: deviceStore,
                                    inventory: inventoryStore,
                                    touchGate: touchGate,
                                    reset: reset,
                                    temporaryUV: temporaryUV,
                                    router: router)
        self.panel = PanelStore(devices: deviceStore,
                              accounts: accountStore,
                              generation: generationStore,
                              inventory: inventoryStore,
                              labels: labelStore,
                              preferences: settings,
                              touchGate: touchGate,
                              decryptor: decryptor,
                              temporaryUV: temporaryUV,
                              router: router)

        temporaryUV.canBegin = { [weak self] in
            guard let self else { return false }
            return !self.manager.hasPendingForm && !self.reset.isResetting
        }
        temporaryUV.onConfigurationChanged = { [weak inventoryStore, weak deviceStore] device in
            // Only refresh a manager snapshot that already exists; the HUD needs no extra read.
            guard inventoryStore?.reading(for: device.path).info != nil else { return }
            await inventoryStore?.refreshInfo(device)
            if let info = inventoryStore?.reading(for: device.path).info {
                deviceStore?.adoptInfo(info, for: device.path)
            }
        }
        touchGate.$isWorking
            .dropFirst()
            .filter { !$0 }
            .sink { [weak temporaryUV] _ in Task { await temporaryUV?.restoreIfDue() } }
            .store(in: &subscriptions)

        labelStore.onCleared = { [weak self] in
            guard let self else { return }
            self.preferences.forgetLastUsed()
            self.panel.labelEditor.focus(self.panel.labelTarget(for: self.panel.selection))
            self.generation.clearResult()
        }

        settings.$lockTimeout
            .dropFirst()
            .sink { [weak deviceStore] ttl in deviceStore?.setPinTTL(ttl) }
            .store(in: &subscriptions)
        inventoryStore.onAuthenticationFailure = { [weak deviceStore] path in deviceStore?.lock(path: path) }
        generationStore.onAuthenticationFailure = { [weak deviceStore] path in deviceStore?.lock(path: path) }
        accountStore.onMutation = { [weak inventoryStore] path in inventoryStore?.invalidateCapacity(on: path) }
        accountStore.onAuthenticationFailure = { [weak deviceStore] path in deviceStore?.lock(path: path) }
        deviceStore.onKeyClosed = { [weak self] path in self?.keyDidClose(path) }
        deviceStore.onSessionLocked = { [weak self] in self?.sessionDidLock() }
        deviceStore.onArmedKeyAppeared = { [weak reset] device in reset?.armedKeyAppeared(device) }
        deviceStore.onResetArmingExpired = { [weak reset] in reset?.armingExpired() }
        reset.onCompleted = { [weak self] device in
            self?.panel.resetDidComplete()
            self?.manager.resetDidComplete(on: device)
        }
    }

    // MARK: - Reactions that cross store boundaries

    /// A key stopped being usable — locked, PIN expired, unplugged.
    ///
    /// Order matters: the panel is told last, once every store it reads from has already
    /// dropped what it held for this key.
    private func keyDidClose(_ path: String) {
        temporaryUV.stop(for: path)
        // The wizard first: it is waiting for exactly this.
        reset.keyDidClose(path)
        // An open receiving window holds derived keys for this key's accounts. Locking has
        // to take that with it, or "locked" would describe the account list while the
        // messages stayed readable in another window.
        decryptor.close(ifBoundTo: path)
        accounts.drop(devicePath: path)
        generation.dropEverything(forDevicePath: path)
        // A key that merely locked keeps what it said about *itself* — that is public
        // information about the model — but loses its credential list, which names other
        // services' accounts. A key that was unplugged loses both: `DeviceStore` has already
        // removed its state by the time this runs, so its absence is the test.
        if devices.state(for: path) == nil {
            inventory.drop(devicePath: path)
        } else {
            inventory.dropInventory(devicePath: path)
        }
        manager.keyDidClose(path)
        panel.keyDidClose(path)
    }

    /// The user walked away: a receiving window left open would keep live keys and decrypted
    /// text around behind the lock screen, and a copied password would still be on the
    /// clipboard. The sending window stays — it holds no key material, and closing it would
    /// throw away what was being written.
    private func sessionDidLock() {
        decryptor.close(ifBoundTo: nil)
        generation.clearClipboard()
        generation.dropEverything()
        accounts.dropAll()
        inventory.dropAll()
        panel.sessionDidLock()
    }

    // MARK: - Links from the system

    /// A `fidopass://` link the user clicked somewhere. Read off the main actor — a key link
    /// costs an argon2id — then handed to the panel, which opens a window with it and
    /// touches nothing. See `IncomingLink`.
    private var incomingLink: Task<Void, Never>?

    func openLink(_ url: URL) {
        incomingLink?.cancel()
        let sealer = accounts.messages
        incomingLink = Task { [weak self] in
            let link = await IncomingLink.classify(url.absoluteString, sealer: sealer)
            guard !Task.isCancelled else { return }
            self?.panel.handleLink(link)
        }
    }
}
