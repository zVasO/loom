import Testing
import LoomAPI
import LoomCLI
import LoomCore
import LoomIPC
import Foundation

// End to end: the built `loom` binary, a real socket, a server answering
// like the app would. What an agent typing in a session actually gets.

@Suite("loom binary — end to end", .serialized)
struct LoomBinaryTests {

    private var productsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug")
    }

    private func socketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-cli-\(UUID().uuidString.prefix(8)).sock")
    }

    /// Answers like the app: the catalog on badge.list, an echo of the
    /// parameters elsewhere, `sessions.list` for the global token only.
    private func appLikeServer(at url: URL, session: SessionID) -> HookSocketServer {
        HookSocketServer(
            socketPath: url,
            validate: { token in token == "session-token" ? session : nil },
            handler: { _, _ in },
            authorize: { token in
                if token == "global-token" { return APIScope.global }
                if token == "session-token" { return APIScope.session(session) }
                return nil
            },
            requests: { scope, request in
                guard let method = APIMethod(rawValue: request.method) else {
                    return APIResponse(id: request.id, error: APIError(code: .unknownMethod, message: request.method))
                }
                if method.requiresGlobalScope, scope != .global {
                    return APIResponse(id: request.id, error: APIError(code: .forbidden, message: "global only"))
                }
                if !method.allowsGlobalScope, scope == .global {
                    return APIResponse(id: request.id, error: APIError(code: .forbidden, message: "session only"))
                }
                switch method {
                case .browserScreenshot:
                    // Like the app: a PNG under the screenshots directory beside the socket.
                    let directory = APIProtocol.screenshotsDirectory(socketPath: url.path)
                        .appendingPathComponent(session.rawValue.uuidString)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent("000001.png")
                    try? Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: file)
                    return .ok(request.id, APIToolContent(
                        text: "### Result\nScreenshot of the visible page",
                        image: APIImageRef(path: file.path, mimeType: "image/png", width: 1, height: 1)))
                case .browserSnapshot:
                    return .ok(request.id, APIToolContent(text: "### Snapshot\n```yaml\n- button \"Add\" [ref=e1]\n```"))
                case .badgeList:
                    return .ok(request.id, APIBadgeListResult(badges: [APIBadge(name: "review", colorHex: "#4CC38A")]))
                case .sessionGet:
                    return .ok(request.id, APISession(id: session.rawValue.uuidString, title: "t", state: "working",
                                                      badges: ["wip"], createdAt: "2026-01-01T00:00:00Z"))
                default:
                    return APIResponse(id: request.id, result: request.params)
                }
            })
    }

    private struct Run {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private func run(_ arguments: [String], environment: [String: String] = [:], stdin: String? = nil) throws -> Run {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("loom")
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["LOOM_SOCKET"] = nil
        env["LOOM_SESSION_TOKEN"] = nil
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus,
                   stdout: String(decoding: stdout, as: UTF8.self),
                   stderr: String(decoding: stderr, as: UTF8.self))
    }

    @Test("inside a session — socket and token from the environment — `loom badge list` prints the catalog")
    func badgeListDepuisLEnvironnement() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let result = try run(["badge", "list"],
                             environment: ["LOOM_SOCKET": url.path, "LOOM_SESSION_TOKEN": "session-token"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("\"review\""))
        #expect(result.stdout.contains("#4CC38A"))
    }

    @Test("`loom badge add` reads the session first, then writes the merged list")
    func badgeAddFusionne() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let result = try run(["badge", "add", "review", "--socket", url.path, "--token", "session-token"])
        #expect(result.status == 0, "\(result.stderr)")
        let echoed = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(echoed["badges"] as? [String] == ["wip", "review"], "the existing badge stays, the new one lands last")
    }

    @Test("a session token asking for every session is refused, and the CLI says why, exit 1")
    func porteeRefusee() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let result = try run(["sessions", "--socket", url.path, "--token", "session-token"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("forbidden"))

        let global = try run(["sessions", "--socket", url.path, "--token", "global-token"])
        #expect(global.status == 0, "\(global.stderr)")
    }

    @Test("an unknown token is reported as such, exit 3, never a hang")
    func tokenInconnu() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let result = try run(["version", "--socket", url.path, "--token", "forged"])
        #expect(result.status == 3)
        #expect(result.stderr.contains("not known"))
    }

    @Test("`loom mcp` speaks JSON-RPC on stdio: initialize, list, call — one line each")
    func mcpDeBoutEnBout() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let script = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"loom_session_get","arguments":{}}}"#,
        ].joined(separator: "\n") + "\n"
        let result = try run(["mcp"], environment: ["LOOM_SOCKET": url.path, "LOOM_SESSION_TOKEN": "session-token"],
                             stdin: script)
        #expect(result.status == 0, "\(result.stderr)")
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3, "three requests answered, the notification silent: \(result.stdout)")
        let responses = try lines.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        #expect(responses[0]["result"]?["serverInfo"]?["name"]?.stringValue == "loom")
        if case .array(let tools)? = responses[1]["result"]?["tools"] {
            #expect(tools.count == APIToolCatalog.all.count)
        } else {
            Issue.record("no tools in the list")
        }
        if case .array(let content)? = responses[2]["result"]?["content"] {
            #expect(content.first?["text"]?.stringValue?.contains("\"state\":\"working\"") == true)
        } else {
            Issue.record("no content in the call result")
        }
    }

    @Test("`loom browser snapshot` prints the Markdown the agent would read, not JSON")
    func snapshotImprimeDuTexte() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let result = try run(["browser", "snapshot"],
                             environment: ["LOOM_SOCKET": url.path, "LOOM_SESSION_TOKEN": "session-token"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.hasPrefix("### Snapshot\n```yaml\n- button \"Add\" [ref=e1]"))
    }

    @Test("`loom browser take_screenshot --out` copies the image Loom wrote")
    func captureCopieeVersOut() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: APIProtocol.screenshotsDirectory(socketPath: url.path))
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("loom-shot-\(UUID().uuidString.prefix(6)).png")
        defer { try? FileManager.default.removeItem(at: out) }

        let result = try run(["browser", "take_screenshot", "--out", out.path],
                             environment: ["LOOM_SOCKET": url.path, "LOOM_SESSION_TOKEN": "session-token"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("Saved to \(out.path)"))
        let data = try Data(contentsOf: out)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("`--out` naming a directory saves inside it and deletes nothing")
    func captureVersUnDossier() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: APIProtocol.screenshotsDirectory(socketPath: url.path))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-out-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: marker)

        let result = try run(["browser", "take_screenshot", "--out", directory.path],
                             environment: ["LOOM_SOCKET": url.path, "LOOM_SESSION_TOKEN": "session-token"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: marker.path), "what was in the directory stays")
        let saved = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        #expect(saved.count == 1)
    }

    @Test("the global token never drives a session's browser")
    func navigateurSansTokenGlobal() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let result = try run(["browser", "snapshot", "--global", "--session", UUID().uuidString,
                              "--socket", url.path, "--token", "global-token"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("forbidden"))
    }

    @Test("`loom mcp` with the browser tools off lists only the metadata tools")
    func mcpSansNavigateur() throws {
        let url = socketURL()
        let server = appLikeServer(at: url, session: SessionID())
        try server.start()
        defer { server.stop() }

        let script = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ].joined(separator: "\n") + "\n"
        let result = try run(["mcp"], environment: ["LOOM_SOCKET": url.path, "LOOM_SESSION_TOKEN": "session-token",
                                                    "LOOM_BROWSER_TOOLS": "0"], stdin: script)
        #expect(result.status == 0, "\(result.stderr)")
        let lines = result.stdout.split(separator: "\n")
        let list = try JSONDecoder().decode(JSONValue.self, from: Data(lines[1].utf8))
        guard case .array(let tools)? = list["result"]?["tools"] else {
            Issue.record("no tools in \(lines[1])")
            return
        }
        #expect(tools.count == APIToolCatalog.tools(browser: false).count)
        #expect(!tools.contains { $0["name"]?.stringValue?.hasPrefix("browser_") == true })
    }
}
