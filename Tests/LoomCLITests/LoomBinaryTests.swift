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
                switch method {
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
}
