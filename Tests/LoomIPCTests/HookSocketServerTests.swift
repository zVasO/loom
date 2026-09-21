import Testing
import LoomAPI
import LoomCore
import LoomIPC
import Foundation

// Seam: the server's public interface + the ADR-0005 wire protocol
// (one JSON line {token, payload} per hook). Tests run on a REAL Unix socket
// in a temporary directory — it is the POSIX contract we verify.

@Suite("HookSocketServer — hook IPC", .serialized)
struct HookSocketServerTests {

    private func socketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-test-\(UUID().uuidString.prefix(8)).sock")
    }

    @Test("the socket is created with 0600 permissions (NFR-S)")
    func socketEnPermissions0600() throws {
        let url = socketURL()
        let server = HookSocketServer(socketPath: url,
                                      validate: { _ in nil },
                                      handler: { _, _ in })
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(permissions == 0o600, "the hooks socket is readable by the user only")
    }

    @Test("a payload with a valid token is delivered to the matching session")
    func payloadValideLivre() async throws {
        let url = socketURL()
        let id = SessionID()
        let received = Received()
        let server = HookSocketServer(
            socketPath: url,
            validate: { token in token == "token-42" ? id : nil },
            handler: { session, payload in received.append((session, payload)) })
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"token":"token-42","payload":{"hook_event_name":"Stop"}}"#, to: url)

        let delivered = await pollUntil { received.all().count == 1 }
        #expect(delivered)
        let (session, payload) = try #require(received.all().first)
        #expect(session == id)
        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(json["hook_event_name"] as? String == "Stop")
    }

    @Test("invalid token: nothing is delivered, ever (NFR-S)")
    func tokenInvalideIgnore() async throws {
        let url = socketURL()
        let received = Received()
        let server = HookSocketServer(
            socketPath: url,
            validate: { _ in nil },
            handler: { session, payload in received.append((session, payload)) })
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"token":"forged","payload":{"hook_event_name":"Stop"}}"#, to: url)
        try await Task.sleep(for: .milliseconds(120))
        #expect(received.all().isEmpty, "an unknown token never gets past the server")
    }

    @Test("multiple lines on a single connection: one delivery each")
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
        #expect(delivered, "framing happens on line endings, not on packets")
    }

    @Test("the loom-hook binary relays a stdin payload all the way to the server (ADR-0005)")
    func binaireHelperDeBoutEnBout() async throws {
        let url = socketURL()
        let id = SessionID()
        let received = Received()
        let server = HookSocketServer(
            socketPath: url,
            validate: { token in token == "helper-token" ? id : nil },
            handler: { session, payload in received.append((session, payload)) })
        try server.start()
        defer { server.stop() }

        let helper = productsDirectory.appendingPathComponent("loom-hook")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--socket", url.path, "--token", "helper-token"]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","last_assistant_message":"done."}"#.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "the helper exits 0 when the relay succeeds")

        let delivered = await pollUntil { received.all().count == 1 }
        #expect(delivered)
        let (_, payload) = try #require(received.all().first)
        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(json["hook_event_name"] as? String == "Stop", "the payload crosses intact")
    }

    /// `.build/debug` is SPM's stable symlink to the products — resolved from
    /// #filePath, independent of the test runner.
    private var productsDirectory: URL {
        URL(fileURLWithPath: #filePath)                     // …/Tests/LoomIPCTests/…
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()                    // repo root
            .appendingPathComponent(".build/debug")
    }

    // MARK: - Tooling

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(SessionID, Data)] = []
        func append(_ item: (SessionID, Data)) { lock.withLock { items.append(item) } }
        func all() -> [(SessionID, Data)] { lock.withLock { items } }
    }

    /// Minimal client: AF_UNIX connect, write one or more lines, close.
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
        #expect(result == 0, "connection to the socket refused (errno \(errno))")
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

@Suite("Socket cohabitation")
struct CohabitationSocketsTests {

    /// Two app instances must NEVER share a path: the second one refuses to
    /// steal the first one's socket (otherwise: silent unlink, orphaned
    /// server, and every hook failing with errno 61).
    @Test("a second server on the same path fails while the first one lives")
    func secondServeurRefuse() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-test-\(UUID().uuidString.prefix(8)).sock")
        let first = HookSocketServer(socketPath: path,
                                     validate: { _ in nil }, handler: { _, _ in })
        try first.start()
        defer { first.stop() }
        let second = HookSocketServer(socketPath: path,
                                      validate: { _ in nil }, handler: { _, _ in })
        #expect(throws: (any Error).self) { try second.start() }
    }

    @Test("a stale socket file (dead instance) is replaced without error")
    func socketPerimeRemplace() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-test-\(UUID().uuidString.prefix(8)).sock")
        let dead = HookSocketServer(socketPath: path,
                                    validate: { _ in nil }, handler: { _, _ in })
        try dead.start()
        dead.stop()   // stop() may or may not leave the file behind: the next one must cope
        FileManager.default.createFile(atPath: path.path, contents: nil)   // guaranteed wreck
        let next = HookSocketServer(socketPath: path,
                                    validate: { _ in nil }, handler: { _, _ in })
        try next.start()
        next.stop()
    }
}

// ADR-0010: the same socket answers requests. Same real-socket discipline;
// the client is LoomAPI's, so the two halves of the wire meet here.
@Suite("Agents API on the hooks socket", .serialized)
struct AgentsAPISocketTests {

    private func socketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-api-\(UUID().uuidString.prefix(8)).sock")
    }

    /// The client blocks on its read; a plain thread keeps the cooperative
    /// pool free for the server's handler task.
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try work() }) }.start()
        }
    }

    private func echoServer(at url: URL, session: SessionID, global: String? = nil) -> HookSocketServer {
        HookSocketServer(
            socketPath: url,
            validate: { token in token == "session-token" ? session : nil },
            handler: { _, _ in },
            authorize: { token in
                if let global, token == global { return .global }
                return token == "session-token" ? .session(session) : nil
            },
            requests: { scope, request in
                let who: String
                switch scope {
                case .session(let id): who = id.rawValue.uuidString
                case .global: who = "global"
                }
                return .ok(request.id, ["method": request.method, "scope": who])
            })
    }

    @Test("a request under a session token is answered on the same connection, id echoed")
    func requeteSousTokenDeSession() async throws {
        let url = socketURL()
        let id = SessionID()
        let server = echoServer(at: url, session: id)
        try server.start()
        defer { server.stop() }

        let client = APIClient(socketPath: url.path, token: "session-token")
        let response = try await blocking { try client.send(APIRequest(id: "r-7", method: .sessionGet)) }
        #expect(response.id == "r-7")
        #expect(response.error == nil)
        #expect(response.result?["scope"]?.stringValue == id.rawValue.uuidString,
                "the token decides the scope, not the request")
        #expect(response.result?["method"]?.stringValue == "session.get")
    }

    @Test("the global token opens the global scope")
    func tokenGlobal() async throws {
        let url = socketURL()
        let server = echoServer(at: url, session: SessionID(), global: "global-secret")
        try server.start()
        defer { server.stop() }

        let client = APIClient(socketPath: url.path, token: "global-secret")
        let answer: [String: String] = try await blocking { try client.call(.sessionsList) }
        #expect(answer["scope"] == "global")
    }

    @Test("an unknown token gets the connection closed, never an answer (NFR-S)")
    func tokenInconnuFermeLaConnexion() async throws {
        let url = socketURL()
        let server = echoServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let client = APIClient(socketPath: url.path, token: "forged", timeout: .seconds(2))
        await #expect(throws: APIClient.ClientError.rejected) {
            try await blocking { try client.send(APIRequest(id: "r", method: .badgeList)) }
        }
    }

    @Test("a server without a request handler drops requests the same way")
    func serveurSansRequetes() async throws {
        let url = socketURL()
        let id = SessionID()
        let server = HookSocketServer(socketPath: url,
                                      validate: { _ in id }, handler: { _, _ in })
        try server.start()
        defer { server.stop() }

        let client = APIClient(socketPath: url.path, token: "any", timeout: .seconds(2))
        await #expect(throws: APIClient.ClientError.rejected) {
            try await blocking { try client.send(APIRequest(id: "r", method: .badgeList)) }
        }
    }

    @Test("a line that is not a request under a valid token is answered invalidRequest")
    func requeteMalformee() async throws {
        let url = socketURL()
        let server = echoServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        // The client does the framing; the malformed body goes raw.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        url.path.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: path, count: min(strlen(path) + 1, buffer.count))
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
        let line = Array((#"{"token":"session-token","request":{"id":"bad","nope":true}}"# + "\n").utf8)
        #expect(write(fd, line, line.count) == line.count)

        let reply = try await blocking { () -> String in
            var received = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 1024)
            while !received.contains(UInt8(ascii: "\n")) {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                received.append(contentsOf: chunk[0..<count])
            }
            return String(decoding: received, as: UTF8.self)
        }
        let response = try APIEnvelope.decodeResponse(Data(reply.trimmingCharacters(in: .newlines).utf8))
        #expect(response.id == "bad", "the id is echoed when the line carried one")
        #expect(response.error?.code == .invalidRequest)
    }

    @Test("hooks keep flowing on a server that also answers requests")
    func hooksToujoursLivres() async throws {
        let url = socketURL()
        let id = SessionID()
        let delivered = Counter()
        let server = HookSocketServer(
            socketPath: url,
            validate: { token in token == "session-token" ? id : nil },
            handler: { _, _ in delivered.increment() },
            authorize: { token in token == "session-token" ? .session(id) : nil },
            requests: { _, request in .ok(request.id, ["ok": true]) })
        try server.start()
        defer { server.stop() }

        let client = APIClient(socketPath: url.path, token: "session-token")
        let answer: [String: Bool] = try await blocking { try client.call(.version) }
        #expect(answer["ok"] == true)

        // The hook path takes the raw envelope: same token, `payload` key.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        url.path.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: path, count: min(strlen(path) + 1, buffer.count))
            }
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let line = Array((#"{"token":"session-token","payload":{"hook_event_name":"Stop"}}"# + "\n").utf8)
        #expect(write(fd, line, line.count) == line.count)
        var attempts = 0
        while delivered.value == 0, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(delivered.value == 1, "a hook line on the same server still reaches the handler")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
