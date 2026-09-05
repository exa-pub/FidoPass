/// The state read from the key before and after an explicit configuration request.
public struct AlwaysUVChange: Equatable, Sendable {
    public let previous: Bool
    public let enabled: Bool
    public var changed: Bool { previous != enabled }

    public init(previous: Bool, enabled: Bool) {
        self.previous = previous
        self.enabled = enabled
    }
}
