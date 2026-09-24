import Foundation

/// How an extension's page is confined (ADR-0011): its origin, what it may
/// load, where it may navigate, whom the bridge listens to. Pure decisions —
/// the WebKit host in LoomWeb applies them.
public enum ExtensionWebPolicy {
    /// Each extension is served from `loom-ext://<id>/`, and only its own
    /// scheme handler answers there.
    public static let scheme = "loom-ext"

    /// Sent with every file the scheme handler serves. No remote load of any
    /// kind — scripts, styles, images, frames, connections all stay on the
    /// extension's own scheme; `http.fetch` is the one door out. `loom-ext:`
    /// is spelled out next to `'self'` because how WebKit matches `'self'` for
    /// a custom scheme is not something to bet the confinement on; each web
    /// view's handler only ever serves its own id.
    public static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self' loom-ext:",
        "style-src 'self' loom-ext: 'unsafe-inline'",
        "img-src 'self' loom-ext: data: blob:",
        "font-src 'self' loom-ext: data:",
        "media-src 'self' loom-ext: data: blob:",
        "connect-src 'self' loom-ext:",
        "frame-src 'none'",
        "child-src 'none'",
        "worker-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
    ].joined(separator: "; ")

    /// The second lock: a content rule list that blocks every http(s) and
    /// ws(s) load, whatever the page's policy says. Fixed text, never built
    /// from a manifest. If WebKit cannot compile it, the extension does not load.
    public static let contentRuleListID = "app.loom.extensions.block-network.v1"
    public static let contentRuleListJSON = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},\
    {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
    """

    public static func url(for extensionID: String) -> URL {
        URL(string: "\(scheme)://\(extensionID)/")!
    }

    /// The page a view opens: the entry itself, so that its relative URLs
    /// resolve from its own folder (`ui/index.html` loads `ui/app.js`).
    public static func entryURL(for extensionID: String, entry: String) -> URL {
        let path = entry.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry
        return URL(string: "\(scheme)://\(extensionID)/\(path)") ?? url(for: extensionID)
    }

    /// Headers of every scheme-handler response.
    public static func responseHeaders(contentType: String, length: Int) -> [String: String] {
        [
            "Content-Type": contentType,
            "Content-Length": String(length),
            "Content-Security-Policy": contentSecurityPolicy,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
    }

    public enum NavigationDecision: Equatable, Sendable {
        case allow
        /// A link the user clicked: it opens in their default browser, never here.
        case openExternally(URL)
        case cancel
    }

    /// The page stays on its own origin. A link the user clicks to the web
    /// opens in their browser; a navigation a script starts on its own goes
    /// nowhere — it would otherwise carry data out in a URL.
    public static func decide(url: URL?, isMainFrame: Bool, isUserClick: Bool,
                              extensionID: String) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == Self.scheme {
            return url.host?.lowercased() == extensionID ? .allow : .cancel
        }
        if isUserClick, isMainFrame, ["https", "http", "mailto"].contains(scheme) {
            return .openExternally(url)
        }
        return .cancel
    }

    /// The bridge answers the extension's own top-level page only — not a
    /// frame, not a page the web view somehow ended up on.
    public static func acceptsMessage(isMainFrame: Bool, frameURL: URL?, extensionID: String) -> Bool {
        guard isMainFrame, let frameURL,
              frameURL.scheme?.lowercased() == scheme,
              frameURL.host?.lowercased() == extensionID
        else { return false }
        return true
    }
}

/// Maps `loom-ext://<id>/<path>` to a file inside the extension's folder —
/// and nowhere else: no `..`, no hidden file, no symbolic link out of the
/// folder, no directory, nothing over the size cap.
public struct ExtensionFileResolver: Sendable {
    public let extensionID: String
    public let root: URL
    public let entry: String
    public static let maxFileBytes = 10 << 20

    public struct Resolved: Equatable, Sendable {
        public var fileURL: URL
        public var contentType: String
    }

    public init(extensionID: String, root: URL, entry: String) {
        self.extensionID = extensionID
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.entry = entry
    }

    public func resolve(_ url: URL) -> Resolved? {
        guard url.scheme?.lowercased() == ExtensionWebPolicy.scheme,
              url.host?.lowercased() == extensionID
        else { return nil }
        var path = url.path
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = entry }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." && !$0.hasPrefix(".") }),
              !path.contains("\\"), !path.contains("\0")
        else { return nil }
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maxFileBytes
        else { return nil }
        return Resolved(fileURL: candidate, contentType: Self.contentType(for: candidate.pathExtension))
    }

    public static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
