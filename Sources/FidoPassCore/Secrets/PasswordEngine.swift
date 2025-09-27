import Foundation

enum PasswordEngine {
    static func alphabet(policy: PasswordPolicy) -> [Character] {
        let lower = Array("abcdefghjkmnpqrstuvwxyz")
        let upper = Array("ABCDEFGHJKMNPQRSTUVWXYZ")
        let digits = Array("23456789")
        let symbols = Array("!#$%&*+-.:;<=>?@^_~")

        var alphabet: [Character] = []
        if policy.useLower { alphabet += lower }
        if policy.useUpper { alphabet += upper }
        if policy.useDigits { alphabet += digits }
        if policy.useSymbols { alphabet += symbols }
        if alphabet.isEmpty { alphabet = lower + upper + digits }
        return alphabet
    }

    static func mapToPassword(_ material: Data, policy: PasswordPolicy) -> String {
        let alphabet = alphabet(policy: policy)
        let alphabetCount = alphabet.count
        precondition(alphabetCount > 1)

        let maxMultiple = (256 / alphabetCount) * alphabetCount
        var characters: [Character] = []
        characters.reserveCapacity(policy.length)

        var requiredClasses: [[Character]] = []
        if policy.useLower { requiredClasses.append(Array("abcdefghjkmnpqrstuvwxyz")) }
        if policy.useUpper { requiredClasses.append(Array("ABCDEFGHJKMNPQRSTUVWXYZ")) }
        if policy.useDigits { requiredClasses.append(Array("23456789")) }
        if policy.useSymbols { requiredClasses.append(Array("!#$%&*+-.:;<=>?@^_~")) }

        var index = 0
        let bytes = [UInt8](material)
        func nextByte() -> UInt8 {
            defer { index += 1 }
            if index >= bytes.count { return 0 }
            return bytes[index]
        }

        while characters.count < policy.length {
            let value = Int(nextByte())
            if value >= maxMultiple { continue }
            characters.append(alphabet[value % alphabetCount])
        }

        if policy.useLower || policy.useUpper || policy.useDigits || policy.useSymbols {
            for (classIndex, characterSet) in requiredClasses.enumerated() {
                if !characters.contains(where: { characterSet.contains($0) }) {
                    let position = Int(bytes[classIndex % bytes.count]) % characters.count
                    let replacement = characterSet[Int(bytes[(classIndex + 7) % bytes.count]) % characterSet.count]
                    characters[position] = replacement
                }
            }
        }
        return String(characters)
    }
}
