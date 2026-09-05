import Foundation
import FidoPassCore

/// Receiving-window state bound to one key. Pasting only locates an account; decrypting
/// requires a button press. Derived keys are cached per credential and nonce until close.
@MainActor
final class MessageDecryptStore: ObservableObject {

    enum Status: Equatable {
        case empty
        /// A prefix of a valid link — the normal state while pasting.
        case incomplete
        case invalid(MessageCryptoError)
        /// Computing locators for the accounts on this key.
        case locating
        case noMatchingAccount
        /// Found the account; waiting for the button.
        case ready(accountId: String)
        case decrypting
        case decrypted(accountId: String)
    }

    @Published var sealedText = "" {
        didSet { sealedTextEdited(from: oldValue) }
    }
    @Published private(set) var message: SealedMessageURL?
    @Published private(set) var account: AccountHandle?
    @Published private(set) var plaintext = ""
    @Published private(set) var status: Status = .empty
    @Published var error: PresentedError?

    let devicePath: String
    let deviceName: String

    private let accounts: AccountStore
    private let touchGate: TouchGate
    /// Keys derived so far, by nonce. One touch each; wiped when the window closes.
    private var keys: [MessageCacheKey: MessageKey] = [:]
    private var lifetime = OperationLease()
    private var revision: UInt64 = 0
    private var parsing: Task<Void, Never>?
    var isParsing: Bool { parsing != nil }
    private var locating: Task<Void, Never>?
    private var applyingProgrammaticEdit = false

    init(accounts: AccountStore,
         touchGate: TouchGate,
         devicePath: String,
         deviceName: String,
         prefilled: SealedMessageURL? = nil) {
        self.accounts = accounts
        self.touchGate = touchGate
        self.devicePath = devicePath
        self.deviceName = deviceName
        if let prefilled { adopt(prefilled) }
    }

    /// The touch prompt this window draws, if the current wait is its own.
    var touch: TouchPrompt? { touchGate.decryptorPrompt }
    var isWorking: Bool { touchGate.isWorking }

    /// Whether any account on this key predates identities. Such an account cannot receive
    /// messages until it is migrated, and "no matching account" is a poor way to say so.
    var hasLegacyAccounts: Bool {
        accounts.accounts(onDevice: devicePath).contains { $0.account.needsMigration }
    }

    /// Whether the button may do anything: a message with an account, no work in flight.
    var canDecrypt: Bool {
        if case .ready = status { return !isWorking }
        if case .decrypted = status { return !isWorking }
        return false
    }

    /// A message that arrived as a link — put it in the field as if it had been pasted.
    func adopt(_ message: SealedMessageURL) {
        applyingProgrammaticEdit = true
        sealedText = message.absoluteString
        applyingProgrammaticEdit = false
        accept(message)
    }

    // MARK: - Reading the message

    private func sealedTextEdited(from oldValue: String) {
        guard !applyingProgrammaticEdit, !oldValue.utf8.elementsEqual(sealedText.utf8) else { return }
        revision += 1
        // Whatever was decrypted belonged to the previous message.
        plaintext = ""
        error = nil
        guard !sealedText.isEmpty else {
            parsing?.cancel()
            locating?.cancel()
            message = nil
            account = nil
            status = .empty
            return
        }
        parsing?.cancel()
        locating?.cancel()
        let text = sealedText
        let inputRevision = revision
        let token = lifetime
        message = nil
        account = nil
        status = .incomplete
        parsing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let outcome = await MessageCryptoWorker.shared.result { try SealedMessageURL(parsing: text) }
            guard let self, !Task.isCancelled, token.isValid, self.revision == inputRevision else { return }
            self.parsing = nil
            switch outcome {
            case .success(let message): self.accept(message)
            case .failure(let error):
                if let known = error as? MessageCryptoError {
                    self.status = known == .incomplete ? .incomplete : .invalid(known)
                } else {
                    self.status = .invalid(.notFidoPassURL)
                    self.error = .plain(error.localizedDescription)
                }
            }
        }
    }

    /// Finds the account the message is for. Nothing on the key is asked; the locators are
    /// computed from what the panel already read, one argon2id per account, off the main actor.
    private func accept(_ parsed: SealedMessageURL) {
        revision += 1
        let token = lifetime
        locating?.cancel()
        message = parsed
        account = nil
        plaintext = ""
        status = .locating
        locating = Task { [weak self] in
            guard let self else { return }
            let found: AccountHandle?
            do {
                found = try await accounts.accountMatching(locator: parsed.locator, nonce: parsed.nonce, onDevice: devicePath)
            } catch {
                found = nil
            }
            guard !Task.isCancelled, token.isValid, self.message == parsed else { return }
            self.account = found
            self.status = found.map { .ready(accountId: $0.id) } ?? .noMatchingAccount
        }
    }

    // MARK: - Decrypting

    /// The button. One touch for a nonce not seen before; none for one that has been.
    func decrypt() async {
        guard canDecrypt, let message, let account else { return }
        error = nil
        let token = lifetime
        let inputRevision = revision
        let cacheKey = MessageCacheKey(credentialId: account.credentialIdB64, nonce: message.nonce)
        do {
            var key: MessageKey
            if let cached = keys[cacheKey] {
                key = cached
            } else {
                key = try await touchGate.withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                                      message: "Deriving the key for “\(account.id)”.",
                                                                      deviceName: deviceName),
                                                          surface: .decryptor) {
                    try await self.accounts.deriveMessageKey(for: account, nonce: message.nonce)
                }
                guard token.isValid, inputRevision == revision else { key.wipe(); return }
                keys[cacheKey] = key
            }
            guard token.isValid, inputRevision == revision, self.message == message else { return }
            status = .decrypting
            let sealer = accounts.messages
            let decryptionKey = key
            let opened = try await MessageCryptoWorker.shared.run { try sealer.open(message, with: decryptionKey) }
            guard token.isValid, inputRevision == revision else { return }
            plaintext = opened
            status = .decrypted(accountId: account.id)
        } catch let known as MessageCryptoError {
            guard token.isValid, inputRevision == revision else { return }
            status = .ready(accountId: account.id)
            error = .plain(known.localizedDescription)
        } catch {
            guard token.isValid, inputRevision == revision, !(error is CancellationError) else { return }
            status = .ready(accountId: account.id)
            self.error = PresentedError(error)
        }
    }

    func abandonTouch() {
        touchGate.abandonTouch()
    }

    /// Drops the message and its text; the keys stay for the next one.
    func clear() {
        parsing?.cancel()
        parsing = nil
        revision += 1
        locating?.cancel()
        applyingProgrammaticEdit = true
        sealedText = ""
        applyingProgrammaticEdit = false
        message = nil
        account = nil
        plaintext = ""
        error = nil
        status = .empty
    }

    /// Ends the session: no text, no keys.
    func close() {
        lifetime.invalidate()
        lifetime = OperationLease()
        if touchGate.surface == .decryptor { touchGate.abandonTouch() }
        clear()
        for nonce in keys.keys { keys[nonce]?.wipe() }
        keys = [:]
    }
}
