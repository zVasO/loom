import Testing
import LoomAPI
import LoomCLI
import LoomCore
import Foundation

// Seam: the JSON-RPC surface, with the API behind a fake — what a client
// sends, what it gets, nothing in between.

@Suite("loom mcp — JSON-RPC over stdio")
struct MCPServerTests {

    private final class Calls: @unchecked Sendable {
        var seen: [(APIMethod, JSONValue)] = []
        var answer: Result<JSONValue, Error> = .success(.object(["ok": .bool(true)]))
    }

    private func server(_ calls: Calls) -> MCPServer {
        MCPServer(call: { method, params in
            calls.seen.append((method, params))
            return try calls.answer.get()
        })
    }

    private func message(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("initialize announces tools and hands the agent its instructions")
    func initialize() {
        let response = server(Calls()).handle(message(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        #expect(response?["id"] == .number(1))
        let result = response?["result"]
        #expect(result?["protocolVersion"]?.stringValue == MCPServer.protocolVersion)
        #expect(result?["capabilities"]?["tools"] != nil)
        #expect(result?["serverInfo"]?["name"]?.stringValue == "loom")
        #expect(result?["instructions"]?.stringValue == APIToolCatalog.instructions)
    }

    @Test("tools/list is the catalog, name for name")
    func toolsList() {
        let response = server(Calls()).handle(message(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        guard case .array(let tools)? = response?["result"]?["tools"] else {
            Issue.record("no tools array"); return
        }
        #expect(tools.compactMap { $0["name"]?.stringValue } == APIToolCatalog.all.map(\.name))
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"]?.stringValue == "object" })
    }

    @Test("tools/call becomes the method's request; the API's answer is the text content")
    func toolsCall() {
        let calls = Calls()
        calls.answer = .success(.object(["title": .string("Fix the cache"), "badges": .array([.string("review")])]))
        let response = server(calls).handle(message(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"loom_session_set_badges","arguments":{"badges":["review"]}}}"#))
        #expect(calls.seen.count == 1)
        #expect(calls.seen.first?.0 == .sessionSetBadges)
        #expect(calls.seen.first?.1 == .object(["badges": .array([.string("review")])]))
        let result = response?["result"]
        #expect(result?["isError"] == .bool(false))
        guard case .array(let content)? = result?["content"], let first = content.first else {
            Issue.record("no content"); return
        }
        #expect(first["type"]?.stringValue == "text")
        #expect(first["text"]?.stringValue == #"{"badges":["review"],"title":"Fix the cache"}"#,
                "the answer travels as compact JSON text, keys sorted")
    }

    @Test("an API error is a tool error, not a JSON-RPC error: the agent reads it and adapts")
    func erreurAPI() {
        let calls = Calls()
        calls.answer = .failure(APIError(code: .conflict, message: "badge review already exists"))
        let response = server(calls).handle(message(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"loom_badge_create","arguments":{"name":"review"}}}"#))
        let result = response?["result"]
        #expect(result?["isError"] == .bool(true))
        #expect(response?["error"] == nil)
        if case .array(let content)? = result?["content"] {
            #expect(content.first?["text"]?.stringValue == "conflict: badge review already exists")
        } else {
            Issue.record("no content")
        }
    }

    @Test("an unknown tool or method is a JSON-RPC error; a notification gets no answer")
    func erreursJSONRPC() {
        let unknownTool = server(Calls()).handle(message(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"loom_launch_rockets"}}"#))
        #expect(unknownTool?["error"]?["code"] == .number(-32602))
        let unknownMethod = server(Calls()).handle(message(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#))
        #expect(unknownMethod?["error"]?["code"] == .number(-32601))
        #expect(server(Calls()).handle(message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)) == nil)
        #expect(server(Calls()).handle(message(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#))?["result"] == .object([:]))
    }

    @Test("a line that is not JSON is a parse error; a blank line is nothing")
    func lignes() {
        let server = server(Calls())
        let garbage = server.handleLine(Data("{nope".utf8)).map { String(decoding: $0, as: UTF8.self) }
        #expect(garbage?.contains("-32700") == true)
        #expect(garbage?.hasSuffix("\n") == true, "one line out")
        #expect(server.handleLine(Data("   \r".utf8)) == nil)
    }
}
