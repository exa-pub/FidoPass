import Foundation

/// Hex in and out, for vectors copied from RFCs and command-line tools.
extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init(hexString hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        precondition(digits.count % 2 == 0, "hex needs an even number of digits")
        var bytes = Data(capacity: digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }
}
