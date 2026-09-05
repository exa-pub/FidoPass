import Foundation

/// The version a bundle was built as. Written by `scripts/build_app.sh` from
/// `scripts/version.sh`; see docs/release.md for what the fields mean.
public struct AppVersion: Equatable, Sendable {
    /// `CFBundleShortVersionString`: `0.18.0` for a release, `0.17.0-dev.8` after it.
    public let short: String
    /// `CFBundleVersion`: what Sparkle compares. Equal to `short` for a release.
    public let build: String
    /// `FidoPassGitCommit`, when the build script knew it.
    public let commit: String?

    public init(short: String, build: String, commit: String? = nil) {
        self.short = short
        self.build = build
        self.commit = commit
    }

    /// Reads a bundle's Info.plist. A bundle without one — the test runner — is `dev`.
    public init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        self.init(short: short ?? "dev",
                  build: build ?? short ?? "dev",
                  commit: info["FidoPassGitCommit"] as? String)
    }

    public static let current = AppVersion(bundle: .main)

    /// A tagged build, as opposed to one made from a commit after the tag.
    public var isRelease: Bool {
        short == build && !short.contains("dev")
    }

    /// `0.18.0`, or `0.17.0-dev.8 (36a05a1)` for a build nobody tagged.
    public var display: String {
        if isRelease { return short }
        if let commit { return "\(short) (\(commit))" }
        return short
    }
}
