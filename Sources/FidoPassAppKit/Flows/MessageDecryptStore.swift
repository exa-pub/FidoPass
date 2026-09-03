import Foundation
import FidoPassCore

/// The receiving window: a sealed message in, its text out. Bound to one security key.
///
/// Pasting a message costs nothing on the key: the account it is for is found by locator
/// from the accounts already read, and the window says which one before anything is
/// touched. Decrypting is an explicit button — a touch is a physical act, not a side effect
/// of a paste — and the key it derives is kept for the window's life, so a second message
/// under the same nonce opens without another touch.
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
    private var keys: [Data: MessageKey] = [:]
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
        guard !applyingProgrammaticEdit, oldValue != sealedText else { return }
        // Whatever was decrypted belonged to the previous message.
        plaintext = ""
        error = nil
        guard !sealedText.isEmpty else {
            locating?.cancel()
            message = nil
            account = nil
            status = .empty
            return
        }
        do {
            accept(try SealedMessageURL(parsing: sealedText))
        } catch let known as MessageCryptoError {
            locating?.cancel()
            message = nil
            account = nil
            status = known == .incomplete ? .incomplete : .invalid(known)
        } catch {
            locating?.cancel()
            message = nil
            account = nil
            status = .invalid(.notFidoPassURL)
        }
    }

    /// Finds the account the message is for. Nothing on the key is asked; the locators are
    /// computed from what the panel already read, one argon2id per account, off the main actor.
    private func accept(_ parsed: SealedMessageURL) {
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
            guard !Task.isCancelled, self.message == parsed else { return }
            self.account = found
            self.status = found.map { .ready(accountId: $0.id) } ?? .noMatchingAccount
        }
    }

    // MARK: - Decrypting

    /// The button. One touch for a nonce not seen before; none for one that has been.
    func decrypt() async {
        guard canDecrypt, let message, let account else { return }
        error = nil
        do {
            let key: MessageKey
            if let cached = keys[message.nonce] {
                key = cached
            } else {
                key = try await touchGate.withTouchPrompt(TouchPrompt(title: "Touch your security key",
                                                                      message: "Deriving the key for “\(account.id)”.",
                                                                      deviceName: deviceName),
                                                          surface: .decryptor) {
                    try await self.accounts.deriveMessageKey(for: account, nonce: message.nonce)
                }
                keys[message.nonce] = key
            }
            guard self.message == message else { return }
            status = .decrypting
            plaintext = try accounts.messages.open(message, with: key)
            status = .decrypted(accountId: account.id)
        } catch let known as MessageCryptoError {
            status = .ready(accountId: account.id)
            error = .plain(known.localizedDescription)
        } catch {
            status = .ready(accountId: account.id)
            self.error = PresentedError(error)
        }
    }

    func abandonTouch() {
        touchGate.abandonTouch()
    }

    /// Drops the message and its text; the keys stay for the next one.
    func clear() {
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
        clear()
        for nonce in keys.keys { keys[nonce]?.wipe() }
        keys = [:]
    }
}
