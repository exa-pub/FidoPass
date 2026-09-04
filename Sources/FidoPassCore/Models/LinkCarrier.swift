import Foundation

/// Carriers for the same public link payload. Writes web links with a fragment; reads
/// web and custom-scheme links. The fragment must never be transmitted by the link page.
public enum LinkCarrier: CaseIterable, Sendable {
    case web
    case app

    /// The carrier the app writes.
    public static let written: LinkCarrier = .web

    /// The web host of the link page. The same domain as `AccountFormat.v2RelyingPartyId`,
    /// but a different thing: the relying party is what a credential is bound to; this is
    /// where a link points.
    public static let webHost = "fidopass.org"

    /// What precedes the payload, exactly as written.
    public var prefix: String {
        switch self {
        case .web: return "https://\(Self.webHost)/link#"
        case .app: return "fidopass://"
        }
    }

    /// The part of `prefix` a reader may match without regard to case: the scheme and the
    /// host, which RFC 3986 (§3.1, §3.2.2) defines as case-insensitive and which mail
    /// clients do capitalise. The rest — the path — is exact: `/LINK` is a different page.
    public var caseInsensitiveHead: String {
        switch self {
        case .web: return "https://\(Self.webHost)"
        case .app: return "fidopass://"
        }
    }
}
