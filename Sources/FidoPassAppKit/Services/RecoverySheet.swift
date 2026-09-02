import Foundation
import FidoPassCore

/// Everything needed to reproduce an account's passwords on another Mac — except the
/// secrets themselves.
///
/// A derived password is a function of the security key, the account id, the label and the
/// policy. The key is in the user's pocket; the rest lives only in their memory and in this
/// machine's `UserDefaults`. Forgetting the label makes the passwords unreproducible even
/// while holding the key, and for a vault master password nothing recovers from that.
///
/// The sheet is deliberately safe to print: it carries no password, no PIN and no backup
/// key, so it can be stored beside the key rather than hidden separately.
struct RecoverySheet {
    let accountId: String
    let kind: AccountKind
    let revision: Int
    let policy: PasswordPolicy
    let labels: [String]
    let deviceDescription: String?
    let generatedAt: Date

    init(account: Account,
         labels: [String],
         deviceDescription: String?,
         generatedAt: Date = Date()) {
        self.accountId = account.id
        self.kind = account.kind
        self.revision = account.revision
        self.policy = account.policy
        self.labels = labels
        self.deviceDescription = deviceDescription
        self.generatedAt = generatedAt
    }

    func render() -> String {
        var lines: [String] = []
        lines.append("FidoPass recovery sheet")
        lines.append(String(repeating: "=", count: 23))
        lines.append("")
        lines.append("This sheet contains NO passwords, NO PIN and NO backup key.")
        lines.append("It is the information you would otherwise have to remember in order")
        lines.append("to reproduce this account's passwords on another Mac.")
        lines.append("")
        lines.append("Account id   : \(accountId)")
        lines.append("Credential   : \(kind == .portable ? "portable (can be copied to a second key)" : "local (bound to one key)")")
        lines.append("Revision     : \(revision)")
        lines.append("Length       : \(policy.length)")
        lines.append("Characters   : \(characterSummary)")
        lines.append("Policy ver.  : \(policy.version)")
        if let deviceDescription {
            lines.append("Security key : \(deviceDescription)")
        }
        lines.append("Generated    : \(Self.dateFormatter.string(from: generatedAt))")
        lines.append("")
        lines.append("Labels used with this account:")
        if labels.isEmpty {
            lines.append("  (none recorded yet — write down every label you use)")
        } else {
            for label in labels {
                lines.append("  • \(label)")
            }
        }
        lines.append("")
        lines.append("To recover: install FidoPass, connect this security key, unlock it with")
        lines.append("its PIN, select the account above and enter the same label. The password")
        lines.append("is derived again from the key — it is never stored anywhere.")
        if kind == .local {
            lines.append("")
            lines.append("WARNING: this credential is bound to a single key. If that key is lost")
            lines.append("or reset, these passwords cannot be recovered by any means.")
        }
        return lines.joined(separator: "\n")
    }

    private var characterSummary: String {
        var classes: [String] = []
        if policy.useLower { classes.append("lower") }
        if policy.useUpper { classes.append("upper") }
        if policy.useDigits { classes.append("digits") }
        if policy.useSymbols { classes.append("symbols") }
        let base = classes.isEmpty ? "letters + digits (fallback)" : classes.joined(separator: ", ")
        return base + " — ambiguous characters (i l o I L O 0 1) never used"
    }

    var suggestedFileName: String {
        let safe = accountId.replacingOccurrences(of: "/", with: "-")
        return "FidoPass-recovery-\(safe).txt"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
