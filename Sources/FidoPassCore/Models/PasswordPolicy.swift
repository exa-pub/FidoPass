import Foundation

public struct PasswordPolicy: Codable, Hashable {
    public var length: Int
    public var useLower: Bool
    public var useUpper: Bool
    public var useDigits: Bool
    public var useSymbols: Bool
    public var avoidAmbiguous: Bool
    public var version: Int

    public init(length: Int = 20,
                useLower: Bool = true,
                useUpper: Bool = true,
                useDigits: Bool = true,
                useSymbols: Bool = true,
                avoidAmbiguous: Bool = true,
                version: Int = 1) {
        self.length = length
        self.useLower = useLower
        self.useUpper = useUpper
        self.useDigits = useDigits
        self.useSymbols = useSymbols
        self.avoidAmbiguous = avoidAmbiguous
        self.version = version
    }
}
