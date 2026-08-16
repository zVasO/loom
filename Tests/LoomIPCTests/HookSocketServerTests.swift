import Testing
import LoomCore
import LoomIPC
import Foundation

// Seam : l'interface publique du serveur + le protocole filaire ADR-0005
// (une ligne JSON {token, payload} par hook). Tests sur un VRAI socket Unix
// dans un dossier temporaire — c'est le contrat POSIX qu'on vérifie.

@Suite("HookSocketServer — IPC des hooks", .serialized)
struct HookSocketServerTests {

    private func socketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-test-\(UUID().uuidString.prefix(8)).sock")
    }

    @Test("le socket est créé en permissions 0600 (NFR-S)")
    func socketEnPermissions0600() throws {
        let url = socketURL()
        let server = HookSocketServer(socketPath: url,
                                      validate: { _ in nil },
                                      handler: { _, _ in })
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(permissions == 0o600, "le socket des hooks n'est lisible que par l'utilisateur")
    }

    @Test("un payload au token valide est livré à la session correspondante")
    func payloadValideLivre() async throws {
        let url = socketURL()
        let id = SessionID()
        let received = Received()
        let server = HookSocketServer(
            socketPath: url,
            validate: { token in token == "jeton-42" ? id : nil },
            handler: { session, payload in received.append((session, payload)) })
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"token":"jeton-42","payload":{"hook_event_name":"Stop"}}"#, to: url)

        let delivered = await pollUntil { received.all().count == 1 }
        #expect(delivered)
        let (session, payload) = try #require(received.all().first)
        #expect(session == id)
        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(json["hook_event_name"] as? String == "Stop")
    }

    @Test("token invalide : rien n'est livré, jamais (NFR-S)")
    func tokenInvalideIgnore() async throws {
        let url = socketURL()
        let received = Received()
        let server = HookSocketServer(
            socketPath: url,
            validate: { _ in nil },
            handler: { session, payload in received.append((session, payload)) })
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"token":"forgé","payload":{"hook_event_name":"Stop"}}"#, to: url)
        try await Task.sleep(for: .milliseconds(120))
        #expect(received.all().isEmpty, "un token inconnu ne franchit jamais le serveur")
    }

    @Test("plusieurs lignes sur une même connexion : une livraison chacune")
    func plusieursLignesUneConnexion() async throws {
        let url = socketURL()
        let id = SessionID()
        let received = Received()
        let server = HookSocketServer(
            socketPath: url,
            validate: { _ in id },
            handler: { session, payload in received.append((session, payload)) })
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"token":"t","payload":{"n":1}}"# + "\n" + #"{"token":"t","payload":{"n":2}}"#, to: url)

        let delivered = await pollUntil { received.all().count == 2 }
        #expect(delivered, "le découpage se fait sur les fins de ligne, pas sur les paquets")
    }

    @Test("le binaire loom-hook relaie un payload stdin jusqu'au serveur (ADR-0005)")
    func binaireHelperDeBoutEnBout() async throws {
        let url = socketURL()
        let id = SessionID()
        let received = Received()
        let server = HookSocketServer(
            socketPath: url,
            validate: { token in token == "jeton-helper" ? id : nil },
            handler: { session, payload in received.append((session, payload)) })
        try server.start()
        defer { server.stop() }

        let helper = productsDirectory.appendingPathComponent("loom-hook")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--socket", url.path, "--token", "jeton-helper"]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","last_assistant_message":"fini."}"#.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "le helper sort en 0 quand le relais réussit")

        let delivered = await pollUntil { received.all().count == 1 }
        #expect(delivered)
        let (_, payload) = try #require(received.all().first)
        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(json["hook_event_name"] as? String == "Stop", "le payload traverse intact")
    }

    /// `.build/debug` est le symlink stable de SPM vers les produits — résolu depuis
    /// #filePath, indépendant du runner de tests.
    private var productsDirectory: URL {
        URL(fileURLWithPath: #filePath)                     // …/Tests/LoomIPCTests/…
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()                    // racine du repo
            .appendingPathComponent(".build/debug")
    }

    // MARK: - Outillage

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(SessionID, Data)] = []
        func append(_ item: (SessionID, Data)) { lock.withLock { items.append(item) } }
        func all() -> [(SessionID, Data)] { lock.withLock { items } }
    }

    /// Client minimal : connexion AF_UNIX, écriture d'une ou plusieurs lignes, fermeture.
    private func sendLine(_ line: String, to url: URL) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        url.path.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: path, count: min(strlen(path) + 1, buffer.count))
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(result == 0, "connexion au socket refusée (errno \(errno))")
        let bytes = Array((line + "\n").utf8)
        #expect(write(fd, bytes, bytes.count) == bytes.count)
    }

    private func pollUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
