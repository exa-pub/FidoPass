import Combine
import Foundation
@preconcurrency import FidoPassCore

/// The application's object graph, built once.
///
/// Everything that used to be assembled inside the panel's store lives here: one key worker,
/// the stores, the coordinators, and the reactions that cross store boundaries — a key
/// going away has to reach the account list, the generated result, the manager's inventory
/// and the editor window, and none of those belongs to the panel.
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
    let editor: EditorCoordinator
    let router: WindowRouter
    /// The menu-bar panel's store.
    let panel: HUDStore

    private var subscriptions: Set<AnyCancellable> = []

    /// The stores are built here rather than injected as defaults: a default argument is
    /// evaluated outside the main actor, and every one of these is main-actor bound.
    init(backend: KeyBackend = LiveKeyBackend(),
         router: WindowRouter,
         preferences: Preferences? = nil,
         labels: LabelStore? = nil,
         emptyConfirmationDelay: Duration = .milliseconds(700),
         enableMonitors: Bool = true) {
        let settings = preferences ?? Preferences()
        // One worker for the whole app: a security key is exclusive, and serialising every
        // call through a single object is what keeps two windows from reaching for it at once.
        let worker = KeyWorker(backend: backend)
        let clipboard = ClipboardService()
        let deviceStore = DeviceStore(worker: worker,
                                      pinTTL: settings.lockTimeout,
                                      emptyConfirmationDelay: emptyConfirmationDelay,
                                      enableMonitors: enableMonitors)
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
        let editor = EditorCoordinator(router: router)

        self.preferences = settings
        self.devices = deviceStore
        self.accounts = accountStore
        self.generation = generationStore
        self.inventory = inventoryStore
        self.labels = labelStore
        self.clipboard = clipboard
        self.touchGate = touchGate
        self.editor = editor
        self.router = router
        self.panel = HUDStore(devices: deviceStore,
                              accounts: accountStore,
                              generation: generationStore,
                              inventory: inventoryStore,
                              labels: labelStore,
                              preferences: settings,
                              touchGate: touchGate,
                              editor: editor,
                              router: router)

        settings.$lockTimeout
            .dropFirst()
            .sink { [weak deviceStore] ttl in deviceStore?.setPinTTL(ttl) }
            .store(in: &subscriptions)
        deviceStore.onKeyClosed = { [weak self] path in self?.keyDidClose(path) }
        deviceStore.onSessionLocked = { [weak self] in self?.sessionDidLock() }
        deviceStore.onArmedKeyAppeared = { [weak self] device in self?.panel.armedKeyAppeared(device) }
    }

    // MARK: - Reactions that cross store boundaries

    /// A key stopped being usable — locked, PIN expired, unplugged.
    ///
    /// Order matters: the panel is told last, once every store it reads from has already
    /// dropped what it held for this key.
    private func keyDidClose(_ path: String) {
        // An open editor holds a derived key for one of this key's accounts. Locking has to
        // take that with it, or "locked" would describe the account list while the secrets
        // stayed reachable in another window.
        editor.close(ifBoundTo: path)
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
        panel.keyDidClose(path)
    }

    /// The user walked away: an editing session left open would keep both the key and the
    /// plaintext on screen behind the lock screen, and a copied password would still be on
    /// the clipboard.
    private func sessionDidLock() {
        editor.close(ifBoundTo: nil)
        generation.clearClipboard()
        generation.dropEverything()
        accounts.dropAll()
        inventory.dropAll()
        panel.sessionDidLock()
    }
}
