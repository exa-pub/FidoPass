import Foundation
import FidoPassCore

/// Sending-window state. Sealing uses a public key link and requires no authenticator.
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
    private let sealer: MessageSealing
    private var keyWork: Task<Void, Never>?
    private var sealWork: Task<Void, Never>?
    /// Set while the store writes into a bound field itself, so the write is not mistaken for
    /// the user editing it.
    private var applyingProgrammaticEdit = false

    init(sealer: MessageSealing, prefilled: EncryptionKeyURL? = nil) {
        self.sealer = sealer
        if let prefilled { adopt(prefilled) }
    }

    /// A key that is known to be valid — just issued, or clicked as a link. No debounce and no
    /// re-reading: the fingerprint is already in it.
    func adopt(_ key: EncryptionKeyURL) {
        keyWork?.cancel()
        applyingProgrammaticEdit = true
        keyText = key.absoluteString
        applyingProgrammaticEdit = false
        self.key = key
        keyStatus = .valid(key.fingerprint)
        reseal()
    }

    var characterCount: Int {
        guard plaintext.utf8.prefix(MessageLimits.maxPlaintextBytes + 1).count <= MessageLimits.maxPlaintextBytes else {
            return characterLimit + 1
        }
        return plaintext.count
    }
    var characterLimit: Int { MessageLimits.maxPlaintextCharacters }

    // MARK: - Key

    private func keyTextEdited(from oldValue: String) {
        guard !applyingProgrammaticEdit, !oldValue.utf8.elementsEqual(keyText.utf8) else { return }
        keyWork?.cancel()
        dropSealed()
        key = nil
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
            let outcome: Result<EncryptionKeyURL, Error> = await MessageCryptoWorker.shared.result { try sealer.parseKey(text) }
            guard !Task.isCancelled, let self, self.keyText.utf8.elementsEqual(text.utf8) else { return }
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
        guard !oldValue.utf8.elementsEqual(plaintext.utf8) else { return }
        sealWork?.cancel()
        sealed = ""
        status = plaintext.isEmpty ? .empty : .sealing
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
        sealed = ""
        status = plaintext.isEmpty ? .empty : .sealing
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
            let outcome: Result<SealedMessageURL, Error> = await MessageCryptoWorker.shared.result { try sealer.seal(text, for: key) }
            guard !Task.isCancelled, let self, self.plaintext.utf8.elementsEqual(text.utf8), self.key == key else { return }
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
