import Foundation
import FidoPassCore

/// The sending window: a key link in, a sealed message out. Bound to no security key.
///
/// Sealing needs nothing but the link, which is the whole point of the scheme — this window
/// works on a Mac with no authenticator plugged in, or none at all. It exists in one of two
/// ways: opened empty from the menu, or opened by the panel with a key it just issued, and
/// a link clicked in another application lands in whichever is open.
@MainActor
final class MessageEncryptStore: ObservableObject {
    /// How long to wait after the last keystroke before recomputing.
    ///
    /// Every edit produces a brand-new message — a fresh ephemeral key is part of the
    /// construction — so recomputing per character would make the output strobe; and reading
    /// a key costs an argon2id, which is not per-character work either.
    static let debounce: Duration = .milliseconds(350)

    enum KeyStatus: Equatable {
        case empty
        /// A prefix of a valid link — the normal state while pasting or typing.
        case incomplete
        /// The link is being read: argon2id, off the main actor.
        case verifying
        case invalid(MessageCryptoError)
        case valid(MessageKeyFingerprint)
    }

    enum Status: Equatable {
        case empty
        /// Text, but no key to seal it under.
        case noKey
        case sealing
        case sealed
        case tooLarge(limit: Int)
        case failed
    }

    @Published var keyText = "" {
        didSet { keyTextEdited(from: oldValue) }
    }
    @Published private(set) var key: EncryptionKeyURL?
    @Published private(set) var keyStatus: KeyStatus = .empty
    @Published var plaintext = "" {
        didSet { plaintextEdited(from: oldValue) }
    }
    /// The sealed message as a link, or empty.
    @Published private(set) var sealed = ""
    @Published private(set) var status: Status = .empty
    /// The account the key on screen was issued for, when the panel opened this window —
    /// so the window can say whose key it is, and warn when that account is not backed up.
    @Published private(set) var issuedFor: Account?

    private let sealer: MessageSealing
    private var keyWork: Task<Void, Never>?
    private var sealWork: Task<Void, Never>?
    /// Set while the store writes into a bound field itself, so the write is not mistaken for
    /// the user editing it.
    private var applyingProgrammaticEdit = false

    init(sealer: MessageSealing, prefilled: EncryptionKeyURL? = nil, issuedFor: Account? = nil) {
        self.sealer = sealer
        if let prefilled { adopt(prefilled, issuedFor: issuedFor) }
    }

    /// A key that is known to be valid — just issued, or clicked as a link. No debounce and no
    /// re-reading: the fingerprint is already in it.
    func adopt(_ key: EncryptionKeyURL, issuedFor account: Account?) {
        keyWork?.cancel()
        applyingProgrammaticEdit = true
        keyText = key.absoluteString
        applyingProgrammaticEdit = false
        self.key = key
        self.issuedFor = account
        keyStatus = .valid(key.fingerprint)
        reseal()
    }

    var characterCount: Int { plaintext.count }
    var characterLimit: Int { MessageLimits.maxPlaintextCharacters }

    // MARK: - Key

    private func keyTextEdited(from oldValue: String) {
        guard !applyingProgrammaticEdit, oldValue != keyText else { return }
        keyWork?.cancel()
        key = nil
        // Whatever key the panel issued, the user is now typing another one.
        issuedFor = nil
        guard !keyText.isEmpty else {
            keyStatus = .empty
            dropSealed()
            return
        }
        keyStatus = .incomplete
        let text = keyText
        let sealer = self.sealer
        keyWork = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.keyStatus = .verifying
            let outcome: Result<EncryptionKeyURL, Error> = await Task.detached {
                Result { try sealer.parseKey(text) }
            }.value
            guard !Task.isCancelled, let self, self.keyText == text else { return }
            switch outcome {
            case .success(let key):
                self.key = key
                self.keyStatus = .valid(key.fingerprint)
                self.reseal()
            case .failure(let error):
                self.key = nil
                self.dropSealed()
                if let known = error as? MessageCryptoError {
                    self.keyStatus = known == .incomplete ? .incomplete : .invalid(known)
                } else {
                    self.keyStatus = .invalid(.notFidoPassURL)
                }
            }
        }
    }

    // MARK: - Text

    private func plaintextEdited(from oldValue: String) {
        guard oldValue != plaintext else { return }
        sealWork?.cancel()
        guard !plaintext.isEmpty else {
            // Clearing the text clears the message at once; waiting out the debounce would
            // leave a stale link sitting next to an empty field.
            sealed = ""
            status = .empty
            return
        }
        sealWork = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.reseal()
        }
    }

    private func reseal() {
        sealWork?.cancel()
        guard !plaintext.isEmpty else {
            sealed = ""
            status = .empty
            return
        }
        guard let key else {
            sealed = ""
            status = .noKey
            return
        }
        let text = plaintext
        let sealer = self.sealer
        status = .sealing
        sealWork = Task { [weak self] in
            let outcome: Result<SealedMessageURL, Error> = await Task.detached {
                Result { try sealer.seal(text, for: key) }
            }.value
            guard !Task.isCancelled, let self, self.plaintext == text, self.key == key else { return }
            switch outcome {
            case .success(let message):
                self.sealed = message.absoluteString
                self.status = .sealed
            case .failure(let error):
                self.sealed = ""
                if case .tooLarge(let limit)? = error as? MessageCryptoError {
                    self.status = .tooLarge(limit: limit)
                } else {
                    self.status = .failed
                }
            }
        }
    }

    private func dropSealed() {
        sealWork?.cancel()
        sealed = ""
        status = plaintext.isEmpty ? .empty : .noKey
    }

    /// Drops the text and the message; the key stays.
    func clear() {
        sealWork?.cancel()
        plaintext = ""
        sealed = ""
        status = .empty
    }
}
