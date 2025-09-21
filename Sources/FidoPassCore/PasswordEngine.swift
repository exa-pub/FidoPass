import Foundation

public enum PasswordEngine {
    static func alphabet(policy: PasswordPolicy) -> [Character] {
        let lower = Array("abcdefghjkmnpqrstuvwxyz") // без i, l, o
        let upper = Array("ABCDEFGHJKMNPQRSTUVWXYZ") // без I, L, O
        let digits = Array("23456789")              // без 0,1
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

        // rejection sampling, избегаем биаса
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
            if idx >= bytes.count { return 0 } // не должен случаться, у нас запас
            return bytes[idx]
        }

        while out.count < policy.length {
            let b = Int(nextByte())
            if b >= maxMultiple { continue }
            out.append(alpha[b % n])
        }

        // Гарантируем включение классов (если требуется)
        if policy.useLower || policy.useUpper || policy.useDigits || policy.useSymbols {
            for (ci, cls) in needClasses.enumerated() {
                if !out.contains(where: { cls.contains($0) }) {
                    // заменим позицию, детерминированно выбрав индекс из материала
                    let pos = Int(bytes[ci % bytes.count]) % out.count
                    let ch = cls[Int(bytes[(ci+7) % bytes.count]) % cls.count]
                    out[pos] = ch
                }
            }
        }
        return String(out)
    }
}
