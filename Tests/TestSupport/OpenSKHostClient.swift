import Foundation
import FidoPassVirtualKeys

extension OpenSKHostClient {
    package static var executable: URL {
        if let override = ProcessInfo.processInfo.environment["FIDOPASS_TEST_AUTHENTICATOR"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/test-authenticator/target/debug/fidopass-test-authenticator")
    }

    package convenience init(seed: UInt8, profile: Profile = .standard) throws {
        try self.init(executable: Self.executable, seed: Data(repeating: seed, count: 32), profile: profile)
    }
}
