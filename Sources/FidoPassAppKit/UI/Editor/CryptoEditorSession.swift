import Foundation
import SwiftUI
import FidoPassCore

/// State of one editing session: the key, the two texts, and the rules that keep them in
/// step without chasing each other.
@MainActor
final class CryptoEditorSession: ObservableObject {
    /// How long to wait after the last keystroke before recomputing.
    ///
    /// Every edit produces a brand-new ciphertext — a fresh nonce is mandatory — so
    /// recomputing per character would make the right pane strobe while typing. A short
    /// pause keeps the panes in step without that.
    static let debounce: Duration = .milliseconds(350)

    enum Status: Equatable {
        case empty
        case sealed
        case decrypted
        case incomplete
        case foreignFormat
        case unsupportedVersion(UInt8)
        case unreadable
        case tooLarge(limit: Int)
        case keyExpired
    }

    @Published var plaintext = "" {
        didSet { edited(.plaintext, from: oldValue, to: plaintext) }
    }
    @Published var ciphertext = "" {
        didSet { edited(.ciphertext, from: oldValue, to: ciphertext) }
    }
    @Published private(set) var status: Status = .empty

    let accountId: String
    let label: String
    let isPortable: Bool

    private var key: EncryptionKey
    private let cipher: SecretCipher
    private var pendingWork: Task<Void, Never>?

    /// Which side the user is editing.
    ///
    /// Without it the two bindings feed each other forever: writing the result into one
    /// pane looks exactly like the user typing there, which recomputes the other, and so on.
    private enum Side { case plaintext, ciphertext }
    private var applyingProgrammaticEdit = false

    init(account: Account, label: String, key: EncryptionKey, cipher: SecretCipher) {
        self.accountId = account.id
        self.label = label
        self.isPortable = account.kind == .portable
        self.key = key
        self.cipher = cipher
    }

    private func edited(_ side: Side, from oldValue: String, to newValue: String) {
        guard !applyingProgrammaticEdit, oldValue != newValue else { return }
        pendingWork?.cancel()

        guard !newValue.isEmpty else {
            // Clearing one side clears the other at once; waiting out the debounce would
            // leave a stale value sitting next to an empty field.
            applyingProgrammaticEdit = true
            switch side {
            case .plaintext:  ciphertext = ""
            case .ciphertext: plaintext = ""
            }
            applyingProgrammaticEdit = false
            status = .empty
            return
        }

        pendingWork = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.recompute(from: side)
        }
    }

    private func recompute(from side: Side) {
        guard key.isUsable else {
            status = .keyExpired
            return
        }
        applyingProgrammaticEdit = true
        defer { applyingProgrammaticEdit = false }

        switch side {
        case .plaintext:
            do {
                ciphertext = try cipher.seal(plaintext, with: key)
                status = .sealed
            } catch let error as SecretCryptoError {
                status = Self.status(for: error)
            } catch {
                status = .unreadable
            }
        case .ciphertext:
            do {
                plaintext = try cipher.open(ciphertext, with: key)
                status = .decrypted
            } catch let error as SecretCryptoError {
                // The plaintext pane keeps its previous content: blanking it on every
                // half-typed character would destroy what the user is working on.
                status = Self.status(for: error)
            } catch {
                status = .unreadable
            }
        }
    }

    private static func status(for error: SecretCryptoError) -> Status {
        switch error {
        case .notBase64:                    return .incomplete
        case .notFidoPassEnvelope:          return .foreignFormat
        case .unsupportedVersion(let value): return .unsupportedVersion(value)
        case .authenticationFailed:         return .unreadable
        case .tooLarge(let limit):          return .tooLarge(limit: limit)
        }
    }

    func clear() {
        pendingWork?.cancel()
        applyingProgrammaticEdit = true
        plaintext = ""
        ciphertext = ""
        applyingProgrammaticEdit = false
        status = .empty
    }

    /// Ends the session: no text, no key.
    func close() {
        clear()
        key.wipe()
    }

    var characterCount: Int { plaintext.count }
    var characterLimit: Int { SecretCrypto.maxPlaintextCharacters }
}
