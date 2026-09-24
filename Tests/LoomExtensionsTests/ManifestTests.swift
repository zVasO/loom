import Testing
import LoomExtensions
import Foundation

// Seam: what an extension declares — its manifest, its permissions, the hosts
// it may reach — read and judged before anything is served (ADR-0011).

@Suite("Extensions — manifest")
struct ManifestTests {

    private func decode(_ json: String) throws -> ExtensionManifest {
        try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    }

    @Test("a minimal manifest takes index.html as its entry and asks for nothing")
    func manifesteMinimal() throws {
        let manifest = try decode(#"{"id":"dev.example.hello","name":"Hello","version":"1.0.0","loomApi":1}"#)
        #expect(manifest.entry == "index.html")
        #expect(manifest.permissions.isEmpty)
        #expect(manifest.contributes.commands.isEmpty)
        try manifest.validate()
    }

    @Test("the id must be lowercase reverse-DNS: it becomes the page's host")
    func identifiant() {
        #expect(ExtensionManifest.isValidID("dev.loom.jira-board"))
        #expect(ExtensionManifest.isValidID("com.example.a1"))
        #expect(!ExtensionManifest.isValidID("Dev.Loom.Jira"), "uppercase never matches the lowercased host")
        #expect(!ExtensionManifest.isValidID("jira"), "one label is not reverse-DNS")
        #expect(!ExtensionManifest.isValidID("dev..jira"))
        #expect(!ExtensionManifest.isValidID("dev.-jira"))
        #expect(!ExtensionManifest.isValidID("dev.jira/../x"))
        #expect(!ExtensionManifest.isValidID(String(repeating: "a.", count: 60) + "b"))
    }

    @Test("an entry that leaves the folder, hides, or is not HTML is refused")
    func pointDEntree() {
        for entry in ["../index.html", "/index.html", "a/../../x.html", ".hidden/index.html",
                      "app.js", "", "a\\b.html", "a//b.html"] {
            let manifest = ExtensionManifest(id: "dev.example.x", name: "X", version: "1", entry: entry)
            #expect(throws: ManifestError.self, "entry \(entry)") { try manifest.validate() }
        }
        let nested = ExtensionManifest(id: "dev.example.x", name: "X", version: "1", entry: "ui/index.html")
        #expect(throws: Never.self) { try nested.validate() }
    }

    @Test("a manifest for another bridge version is refused, not run with less")
    func versionDuPont() {
        let manifest = ExtensionManifest(id: "dev.example.x", name: "X", version: "1", loomApi: 2)
        #expect(throws: ManifestError.unsupportedAPI(2)) { try manifest.validate() }
    }

    @Test("an unknown permission refuses the manifest (fail closed)")
    func permissionInconnue() {
        #expect(throws: ManifestError.self) {
            try decode(#"{"id":"dev.example.x","name":"X","version":"1","loomApi":1,"permissions":{"filesystem":["/"]}}"#)
        }
        #expect(throws: ManifestError.self) {
            try decode(#"{"id":"dev.example.x","name":"X","version":"1","loomApi":1,"permissions":{"sessions":["write"]}}"#)
        }
    }

    @Test("commands need a clean id, a title, and no twin")
    func commandes() {
        let twin = ExtensionManifest(id: "dev.example.x", name: "X", version: "1",
                                     contributes: .init(commands: [.init(id: "refresh", title: "Refresh"),
                                                                   .init(id: "refresh", title: "Again")]))
        #expect(throws: ManifestError.self) { try twin.validate() }
        let untitled = ExtensionManifest(id: "dev.example.x", name: "X", version: "1",
                                         contributes: .init(commands: [.init(id: "go", title: "  ")]))
        #expect(throws: ManifestError.self) { try untitled.validate() }
    }

    @Test("loading from a folder reads loom-extension.json and says what is wrong")
    func chargementDepuisUnDossier() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: ManifestError.self) { try ExtensionManifest.load(from: folder) }
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent(ExtensionManifest.fileName))
        #expect(throws: ManifestError.self) { try ExtensionManifest.load(from: folder) }
        try Data(#"{"id":"dev.example.ok","name":"OK","version":"0.1","loomApi":1,"permissions":{"network":["*.atlassian.net"],"sessions":["read","launch"]}}"#.utf8)
            .write(to: folder.appendingPathComponent(ExtensionManifest.fileName))
        let manifest = try ExtensionManifest.load(from: folder)
        #expect(manifest.permissions.sessions == [.read, .launch])
    }
}

@Suite("Extensions — host patterns")
struct HostPatternTests {

    @Test("*.atlassian.net reaches the subdomains, never the bare domain nor a look-alike")
    func joker() throws {
        let pattern = try HostPattern("*.atlassian.net")
        #expect(pattern.matches(host: "acme.atlassian.net"))
        #expect(pattern.matches(host: "ACME.Atlassian.NET."))
        #expect(!pattern.matches(host: "atlassian.net"))
        #expect(!pattern.matches(host: "evilatlassian.net"))
        #expect(!pattern.matches(host: "atlassian.net.evil.com"))
    }

    @Test("an exact host reaches itself only")
    func hoteExact() throws {
        let pattern = try HostPattern("api.linear.app")
        #expect(pattern.matches(host: "api.linear.app"))
        #expect(!pattern.matches(host: "x.api.linear.app"))
    }

    @Test("too broad, an address, a port or a path is refused")
    func motifsRefuses() {
        for pattern in ["*", "*.com", "localhost", "127.0.0.1", "10.0.0.1", "example.com:8443",
                        "example.com/path", "exa mple.com", "-bad.com", "*.*.com", "", "é.com"] {
            #expect(throws: HostPattern.PatternError.self, "\(pattern)") { try HostPattern(pattern) }
        }
    }

    @Test("only https on the default port, with no credentials in the URL, is allowed")
    func urlsAutorisees() throws {
        let patterns = [try HostPattern("*.atlassian.net")]
        #expect(HostPattern.allows(URL(string: "https://acme.atlassian.net/rest/api/3/myself")!, patterns))
        #expect(HostPattern.allows(URL(string: "https://acme.atlassian.net:443/x")!, patterns))
        #expect(!HostPattern.allows(URL(string: "http://acme.atlassian.net/")!, patterns))
        #expect(!HostPattern.allows(URL(string: "https://acme.atlassian.net:8443/")!, patterns))
        #expect(!HostPattern.allows(URL(string: "https://user:pw@acme.atlassian.net/")!, patterns))
        #expect(!HostPattern.allows(URL(string: "https://example.com/")!, patterns))
    }
}

@Suite("Extensions — permissions")
struct PermissionsTests {

    @Test("a new host or a new access needs consent; dropping one does not")
    func consentement() {
        let granted = ExtensionPermissions(network: ["*.atlassian.net"], sessions: [.read])
        let grown = ExtensionPermissions(network: ["*.atlassian.net", "api.github.com"], sessions: [.read, .launch])
        let missing = grown.missing(from: granted)
        #expect(missing.network == ["api.github.com"])
        #expect(missing.sessions == [.launch])
        let shrunk = ExtensionPermissions(network: [], sessions: [.read])
        #expect(shrunk.missing(from: granted).isEmpty)
        #expect(!grown.missing(from: nil).isEmpty, "nothing granted: everything asked is missing")
    }

    @Test("an extension runs with its asks cut down to the grant")
    func intersection() {
        let asked = ExtensionPermissions(network: ["*.atlassian.net", "api.github.com"], sessions: [.read, .launch],
                                         projects: [.read])
        let granted = ExtensionPermissions(network: ["*.ATLASSIAN.net"], sessions: [.read])
        let effective = asked.intersection(granted)
        #expect(effective.network == ["*.atlassian.net"])
        #expect(effective.sessions == [.read])
        #expect(effective.projects.isEmpty)
        #expect(effective.allows(.sessions(.read)))
        #expect(!effective.allows(.sessions(.launch)))
        #expect(effective.allows(.network))
    }

    @Test("the consent sheet says every permission in plain words")
    func resume() {
        let permissions = ExtensionPermissions(network: ["*.atlassian.net"], sessions: [.read, .launch],
                                               projects: [.read])
        #expect(permissions.summary.count == 4)
        #expect(permissions.summary.first == "Connect to https://*.atlassian.net")
    }
}
