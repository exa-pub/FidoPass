import Foundation

/// Makes invisible label bytes visible in confirmations and history, without changing them.
enum LabelDisplay {
    static func text(_ label: String) -> String {
        let scalars = Array(label.unicodeScalars)
        return scalars.enumerated().map { index, scalar in
            switch scalar {
            case " " where index == 0 || index == scalars.count - 1: return "␠"
            case "\t": return "⇥"
            case "\n": return "↵"
            case "\r": return "␍"
            case "\u{00A0}": return "⍽"
            default:
                if CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format {
                    return String(format: "[U+%04X]", scalar.value)
                }
                return String(scalar)
            }
        }.joined()
    }
}
