import Testing
import LoomExtensions
import Foundation

// Seam: how a page is confined — which file a `loom-ext://` URL serves, where
// the page may navigate, whom the bridge answers. Real folders and real
// symbolic links in the temp directory; WebKit only applies these answers.

@Suite("Extensions — file serving and web policy")
struct WebPolicyTests {

    private func makeExtension() throws -> (root: URL, resolver: ExtensionFileResolver) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-ext-files-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8).write(to: root.appendingPathComponent("app.js"))
        try Data("body{}".utf8).write(to: root.appendingPathComponent("assets/style.css"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".env"))
        return (root, ExtensionFileResolver(extensionID: "dev.example.x", root: root, entry: "index.html"))
    }

    @Test("the root serves the entry; files carry their content type")
    func fichiersServis() throws {
        let (root, resolver) = try makeExtension()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try #require(resolver.resolve(URL(string: "loom-ext://dev.example.x/")!))
        #expect(index.fileURL.lastPathComponent == "index.html")
        #expect(index.contentType.hasPrefix("text/html"))
        #expect(resolver.resolve(URL(string: "loom-ext://dev.example.x/app.js")!)?.contentType
                == "text/javascript; charset=utf-8")
        #expect(resolver.resolve(URL(string: "loom-ext://dev.example.x/assets/style.css?v=2")!) != nil)
    }

    @Test("another extension's host, a parent path, a hidden file or a folder is never served")
    func fichiersRefuses() throws {
        let (root, resolver) = try makeExtension()
        defer { try? FileManager.default.removeItem(at: root) }
        for raw in ["loom-ext://dev.other.x/index.html",
                    "loom-ext://dev.example.x/../etc/hosts",
                    "loom-ext://dev.example.x/assets/%2E%2E/%2E%2E/etc/hosts",
                    "loom-ext://dev.example.x/.env",
                    "loom-ext://dev.example.x/assets",
                    "loom-ext://dev.example.x/missing.js",
                    "https://dev.example.x/index.html"] {
            #expect(resolver.resolve(URL(string: raw)!) == nil, "\(raw)")
        }
    }

    @Test("a symbolic link that points out of the folder is not followed")
    func lienSymboliqueSortant() throws {
        let (root, resolver) = try makeExtension()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("hosts.txt"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(resolver.resolve(URL(string: "loom-ext://dev.example.x/hosts.txt")!) == nil)
    }

    @Test("the page stays home: its own origin loads, a clicked link opens outside, a script's navigation goes nowhere")
    func navigation() {
        let id = "dev.example.x"
        #expect(ExtensionWebPolicy.decide(url: URL(string: "loom-ext://dev.example.x/board.html"),
                                          isMainFrame: true, isUserClick: false, extensionID: id) == .allow)
        #expect(ExtensionWebPolicy.decide(url: URL(string: "loom-ext://dev.other.x/"),
                                          isMainFrame: true, isUserClick: true, extensionID: id) == .cancel)
        let jira = URL(string: "https://acme.atlassian.net/browse/PROJ-1")!
        #expect(ExtensionWebPolicy.decide(url: jira, isMainFrame: true, isUserClick: true, extensionID: id)
                == .openExternally(jira))
        #expect(ExtensionWebPolicy.decide(url: jira, isMainFrame: true, isUserClick: false, extensionID: id)
                == .cancel, "a script carrying data out in a URL")
        #expect(ExtensionWebPolicy.decide(url: URL(string: "file:///etc/hosts"),
                                          isMainFrame: true, isUserClick: true, extensionID: id) == .cancel)
        #expect(ExtensionWebPolicy.decide(url: URL(string: "about:blank"),
                                          isMainFrame: true, isUserClick: false, extensionID: id) == .cancel)
    }

    @Test("a view opens its entry itself, so a nested entry's relative URLs stay in its folder")
    func urlDEntree() {
        #expect(ExtensionWebPolicy.entryURL(for: "dev.example.x", entry: "index.html").absoluteString
                == "loom-ext://dev.example.x/index.html")
        let nested = ExtensionWebPolicy.entryURL(for: "dev.example.x", entry: "ui/index.html")
        #expect(URL(string: "app.js", relativeTo: nested)?.absoluteURL.path == "/ui/app.js")
    }

    @Test("the bridge answers the extension's own top-level page only")
    func origineDesMessages() {
        let id = "dev.example.x"
        let own = URL(string: "loom-ext://dev.example.x/index.html")
        #expect(ExtensionWebPolicy.acceptsMessage(isMainFrame: true, frameURL: own, extensionID: id))
        #expect(!ExtensionWebPolicy.acceptsMessage(isMainFrame: false, frameURL: own, extensionID: id))
        #expect(!ExtensionWebPolicy.acceptsMessage(isMainFrame: true,
                                                   frameURL: URL(string: "loom-ext://dev.other.x/"), extensionID: id))
        #expect(!ExtensionWebPolicy.acceptsMessage(isMainFrame: true,
                                                   frameURL: URL(string: "https://dev.example.x/"), extensionID: id))
        #expect(!ExtensionWebPolicy.acceptsMessage(isMainFrame: true, frameURL: nil, extensionID: id))
    }

    @Test("the content rule list is valid JSON blocking http(s) and ws(s)")
    func listeDeRegles() throws {
        let rules = try #require(try JSONSerialization.jsonObject(
            with: Data(ExtensionWebPolicy.contentRuleListJSON.utf8)) as? [[String: Any]])
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        #expect(filters == ["^https?://", "^wss?://"])
        #expect(rules.allSatisfy { ($0["action"] as? [String: Any])?["type"] as? String == "block" })
    }

    @Test("every served file carries the policy: nothing remote, no frame, no store")
    func politiqueDeContenu() {
        let csp = ExtensionWebPolicy.contentSecurityPolicy
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("connect-src 'self' loom-ext:"))
        #expect(csp.contains("frame-src 'none'"))
        #expect(!csp.contains("https:"), "no remote source of any kind")
        #expect(!csp.contains("unsafe-eval"))
        let headers = ExtensionWebPolicy.responseHeaders(contentType: "text/html", length: 3)
        #expect(headers["Content-Security-Policy"] == csp)
        #expect(headers["Cache-Control"] == "no-store")
    }
}
