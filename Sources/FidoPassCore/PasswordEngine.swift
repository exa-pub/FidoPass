import Foundation

public enum PasswordEngine {
    static func alphabet(policy: PasswordPolicy) -> [Character] {
        let lower = Array("abcdefghjkmnpqrstuvwxyz") // omit i, l, o
        let upper = Array("ABCDEFGHJKMNPQRSTUVWXYZ") // omit I, L, O
        let digits = Array("23456789")              // omit 0,1
        let symbols = Array("!#$%&*+-.:;<=>?@^_~")

        var alpha: [Character] = []
        if policy.useLower { alpha += lower }
        if policy.useUpper { alpha += upper }
        if policy.useDigits { alpha += digits }
        if policy.useSymbols { alpha += symbols }
        if alpha.isEmpty { alpha = lower + upper + digits }
        return alpha
    }

    public static func mapToPassword(_ material: Data, policy: PasswordPolicy) -> String {
        let alpha = alphabet(policy: policy)
        let n = alpha.count
        precondition(n > 1)

        // rejection sampling to avoid bias
        let maxMultiple = (256 / n) * n
        var out: [Character] = []
        out.reserveCapacity(policy.length)

        var needClasses: [[Character]] = []
        if policy.useLower { needClasses.append(Array("abcdefghjkmnpqrstuvwxyz")) }
        if policy.useUpper { needClasses.append(Array("ABCDEFGHJKMNPQRSTUVWXYZ")) }
        if policy.useDigits { needClasses.append(Array("23456789")) }
        if policy.useSymbols { needClasses.append(Array("!#$%&*+-.:;<=>?@^_~")) }

        var idx = 0
        let bytes = [UInt8](material)
        func nextByte() -> UInt8 {
            defer { idx += 1 }
            if idx >= bytes.count { return 0 } // should never fire; we request enough entropy
            return bytes[idx]
        }

        while out.count < policy.length {
            let b = Int(nextByte())
            if b >= maxMultiple { continue }
            out.append(alpha[b % n])
        }

        // Ensure required character classes are present when requested
        if policy.useLower || policy.useUpper || policy.useDigits || policy.useSymbols {
            for (ci, cls) in needClasses.enumerated() {
                if !out.contains(where: { cls.contains($0) }) {
                    // replace an index deterministically based on the entropy material
                    let pos = Int(bytes[ci % bytes.count]) % out.count
                    let ch = cls[Int(bytes[(ci+7) % bytes.count]) % cls.count]
                    out[pos] = ch
                }
            }
        }
        return String(out)
    }
}
