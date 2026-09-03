import Foundation

/// The two ways a link is dressed. The payload — `hpkev1?…` or `hpkeblobv1?…` — is the
/// same in both; the carrier is what comes before it.
///
/// `.web` is what the app writes: an `https://` link is made clickable everywhere, says what
/// it is, and someone without the app lands on a page that explains and hands the payload
/// on to `fidopass://` (`fe/link/index.html`). `.app` is what the system delivers to the
/// app on a click (`CFBundleURLTypes`), so it has to stay readable for that redirect to
/// work. Both are read; the app never has to guess which one it was given.
///
/// The payload rides in the `https` link's *fragment*. A fragment is never sent to the
/// server (RFC 3986 §3.5) — not in the request, not in the Referer — so `fidopass.org` sees
/// neither keys nor messages nor locators. Everything in a link is public by construction,
/// but "public" and "in somebody's server log" are different things, and a locator in a log
/// would tie messages to a recipient.
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
}
