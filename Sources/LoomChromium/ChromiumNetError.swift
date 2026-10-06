import Foundation

/// A Chromium load failure in the words the WebKit engine gives the agent
/// (AgentBrowser's `failure(_:)`, docs/agent-browser.md "Dépannage"): the agent
/// reads one wording whichever engine drives the page.
public enum ChromiumNetError {

    /// `errorText` as Page.navigate or Network.loadingFailed give it
    /// ("net::ERR_CONNECTION_REFUSED"). nil: not a failure, a load cancelled
    /// or superseded (a download, a 204, a newer navigation).
    ///
    /// In local-only mode a refused request meets ChromiumFence, which Chromium
    /// reports as a proxy or tunnel failure: that is the block, said as such.
    public static func message(errorText: String, url: URL?, localOnly: Bool) -> String? {
        var code = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("net::") { code = String(code.dropFirst(5)) }
        guard !code.isEmpty, code != "ERR_ABORTED" else { return nil }

        let host = Self.host(of: url)
        let place: String
        if let host {
            if let port = url?.port { place = "\(host):\(port)" } else { place = host }
        } else {
            place = url?.absoluteString ?? "the page"
        }
        let blocked = "\(host ?? url?.absoluteString ?? "this address") is outside local sites only "
            + "(Loom's Settings ▸ Agents lists the hosts it lets through)"
        // A plain http request the fence closes comes back as a dropped
        // connection, not a proxy error; an allowed host can drop one too.
        var mayBeFenced = false
        if localOnly, let host { mayBeFenced = !ChromiumFence.bypassesAsLoopback(host) }
        let orBlocked = mayBeFenced
            ? " (or it is outside local sites only: Loom's Settings ▸ Agents lists the hosts it lets through)"
            : ""

        switch code {
        case "ERR_CONNECTION_REFUSED":
            return "nothing is listening on \(place) — is the dev server running?"
        case "ERR_NAME_NOT_RESOLVED", "ERR_NAME_RESOLUTION_FAILED":
            return "unknown host \(place)"
        case "ERR_INTERNET_DISCONNECTED":
            return "\(place): the Internet connection appears to be offline"
        case "ERR_ADDRESS_UNREACHABLE":
            return "no route to \(place)"
        case "ERR_CONNECTION_TIMED_OUT", "ERR_TIMED_OUT":
            return "\(place) did not answer in time"
        case "ERR_EMPTY_RESPONSE":
            return "\(place) closed the connection without answering" + orBlocked
        case "ERR_CONNECTION_CLOSED":
            return "\(place) closed the connection" + orBlocked
        case "ERR_CONNECTION_RESET":
            return "the connection to \(place) was reset" + orBlocked
        case "ERR_TUNNEL_CONNECTION_FAILED":
            return localOnly ? blocked : "the network proxy refused the connection to \(place)"
        case "ERR_PROXY_CONNECTION_FAILED":
            return localOnly ? blocked : "the network proxy could not be reached to load \(place)"
        case "ERR_BLOCKED_BY_CLIENT":
            return localOnly ? blocked : "Loom's browser blocked \(place)"
        case "ERR_UNKNOWN_URL_SCHEME":
            return "\(url?.absoluteString ?? "this address") cannot be opened — http(s) only"
        case "ERR_FILE_NOT_FOUND":
            if let url, url.isFileURL { return "no file at \(url.path(percentEncoded: false))" }
            return "no file at \(place)"
        case "ERR_UNSAFE_PORT":
            if let port = url?.port { return "port \(port) is one browsers refuse to open — use another port" }
            return "\(place) uses a port browsers refuse to open"
        case "ERR_HTTP_RESPONSE_CODE_FAILURE":
            return "\(place) answered with an HTTP error and an empty page"
        default:
            if code.hasPrefix("ERR_CERT") || code.hasPrefix("ERR_SSL_") || code == "ERR_BAD_SSL_CLIENT_AUTH_CERT" {
                return "the TLS connection to \(place) failed (\(code)) — a local dev server usually speaks http"
            }
            return "could not load \(url?.absoluteString ?? "the page"): \(code)"
        }
    }

    /// The URL's host, an IPv6 address in brackets so a port after it reads
    /// as one. nil when there is none (about:blank, data:, a file).
    static func host(of url: URL?) -> String? {
        guard var name = url?.host(), !name.isEmpty else { return nil }
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        return name.contains(":") ? "[\(name)]" : name
    }
}
