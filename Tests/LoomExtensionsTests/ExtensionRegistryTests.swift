import Testing
import LoomExtensions
import Foundation

// Seam: the extensions on disk — install, link, consent, removal — in real
// temp folders, with the in-memory secret store standing in for the Keychain.

@Suite("Extensions — registry")
struct ExtensionRegistryTests {

    private struct Sandbox {
        let base: URL
        let registry: ExtensionRegistry
        let secrets: InMemorySecretStore

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("loom-registry-\(UUID().uuidString)")
            secrets = InMemorySecretStore()
            registry = ExtensionRegistry(directory: base.appendingPathComponent("extensions"), secrets: secrets)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }

        func source(id: String, network: [String] = ["*.atlassian.net"], sessions: [String] = ["read"]) throws -> URL {
            let folder = base.appendingPathComponent("src-\(id)-\(UUID().uuidString.prefix(4))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(id: id, network: network, sessions: sessions, in: folder)
            try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
            return folder
        }

        func write(id: String, network: [String], sessions: [String], in folder: URL) throws {
            let manifest: [String: Any] = [
                "id": id, "name": id, "version": "1.0.0", "loomApi": 1,
                "permissions": ["network": network, "sessions": sessions],
            ]
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: folder.appendingPathComponent(ExtensionManifest.fileName))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: base) }
    }

    @Test("an installed copy is ready with what was granted, and survives a rescan")
    func installation() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let source = try box.source(id: "dev.example.jira")
        let manifest = try box.registry.inspect(source)
        let installed = try box.registry.install(from: source, granting: manifest.permissions)
        #expect(installed.status == .ready)
        #expect(!installed.isLinked)
        #expect(FileManager.default.fileExists(atPath: box.registry.installedDirectory
            .appendingPathComponent("dev.example.jira/index.html").path))

        let fresh = ExtensionRegistry(directory: box.registry.directory, secrets: box.secrets)
        fresh.scan()
        #expect(fresh.extensionNamed("dev.example.jira")?.status == .ready)
    }

    @Test("a manifest that grows its asks waits for consent, and approval grants exactly the asks")
    func consentementApresMiseAJour() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let source = try box.source(id: "dev.example.jira")
        try box.registry.link(source, granting: try box.registry.inspect(source).permissions)
        try box.write(id: "dev.example.jira", network: ["*.atlassian.net", "api.github.com"],
                      sessions: ["read", "launch"], in: source)
        box.registry.scan()
        guard case .needsConsent(let missing) = box.registry.extensionNamed("dev.example.jira")?.status else {
            Issue.record("expected needsConsent")
            return
        }
        #expect(missing.network == ["api.github.com"])
        #expect(missing.sessions == [.launch])

        try box.registry.approve("dev.example.jira")
        #expect(box.registry.extensionNamed("dev.example.jira")?.status == .ready)
        #expect(box.registry.extensionNamed("dev.example.jira")?.effectivePermissions.sessions == [.read, .launch])
    }

    @Test("an install never grants more than the manifest asks")
    func jamaisPlusQueDemande() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let source = try box.source(id: "dev.example.small", network: [], sessions: [])
        let installed = try box.registry.install(from: source, granting: ExtensionPermissions(
            network: ["*.evil.com"], sessions: [.launch]))
        #expect(installed.granted?.isEmpty == true)
    }

    @Test("a disabled extension stays known but does not run")
    func desactivation() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let source = try box.source(id: "dev.example.jira")
        try box.registry.install(from: source, granting: try box.registry.inspect(source).permissions)
        try box.registry.setEnabled(false, for: "dev.example.jira")
        #expect(box.registry.extensionNamed("dev.example.jira")?.status == .disabled)
        try box.registry.setEnabled(true, for: "dev.example.jira")
        #expect(box.registry.extensionNamed("dev.example.jira")?.status == .ready)
    }

    @Test("removal takes the copy, the storage and the secrets — never a linked source folder")
    func suppression() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let copied = try box.source(id: "dev.example.copy")
        try box.registry.install(from: copied, granting: try box.registry.inspect(copied).permissions)
        let linked = try box.source(id: "dev.example.linked")
        try box.registry.link(linked, granting: try box.registry.inspect(linked).permissions)
        for id in ["dev.example.copy", "dev.example.linked"] {
            try ExtensionStorage(file: box.registry.storageFile(for: id)).set(.bool(true), for: "k")
            try box.secrets.setSecret("t", "token", for: id)
        }

        try box.registry.remove("dev.example.copy")
        try box.registry.remove("dev.example.linked")

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: box.registry.installedDirectory.appendingPathComponent("dev.example.copy").path))
        #expect(fm.fileExists(atPath: linked.appendingPathComponent("index.html").path), "the developer's folder")
        #expect(!fm.fileExists(atPath: box.registry.storageFile(for: "dev.example.copy").path))
        #expect(!fm.fileExists(atPath: box.registry.storageFile(for: "dev.example.linked").path))
        #expect(box.secrets.keys(for: "dev.example.copy").isEmpty)
        #expect(box.secrets.keys(for: "dev.example.linked").isEmpty)
        #expect(box.registry.extensions.isEmpty)
    }

    @Test("an id both installed and linked is refused; a broken folder becomes a problem, not a crash")
    func conflitsEtProblemes() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let source = try box.source(id: "dev.example.jira")
        try box.registry.install(from: source, granting: .empty)
        #expect(throws: ExtensionRegistry.RegistryError.self) {
            try box.registry.link(source, granting: .empty)
        }
        let broken = box.registry.installedDirectory.appendingPathComponent("dev.example.broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent(ExtensionManifest.fileName))
        let misnamed = try box.source(id: "dev.example.real")
        try FileManager.default.copyItem(at: misnamed,
                                         to: box.registry.installedDirectory.appendingPathComponent("dev.example.fake"))
        box.registry.scan()
        #expect(box.registry.problems.count == 2)
        #expect(box.registry.extensionNamed("dev.example.jira") != nil, "the rest still loads")
    }

    @Test("a copy dropped in by hand is on, but granted nothing until approved")
    func copieManuelle() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let source = try box.source(id: "dev.example.dropped")
        try FileManager.default.createDirectory(at: box.registry.installedDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source,
                                         to: box.registry.installedDirectory.appendingPathComponent("dev.example.dropped"))
        box.registry.scan()
        guard case .needsConsent = box.registry.extensionNamed("dev.example.dropped")?.status else {
            Issue.record("a hand-dropped copy must ask first")
            return
        }
    }
}
