import LoomAPI
import Foundation

/// The API as MCP tools, over stdio: JSON-RPC 2.0, one message per line.
/// Three methods carry everything — `initialize`, `tools/list`, `tools/call` —
/// and each tool call is one API request. No state, no logic: the catalog
/// is the tool list, the API's answer is the tool's result.
public struct MCPServer {

    public typealias Call = (_ method: APIMethod, _ params: JSONValue) throws -> JSONValue

    /// The MCP revision this server speaks; a client asking for another gets
    /// this one back and decides.
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "loom"

    private let call: Call

    public init(call: @escaping Call) {
        self.call = call
    }

    /// Reads stdin line by line until it closes, answers on stdout. Notifications
    /// (no id) get no answer, as JSON-RPC demands.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let reply = handleLine(Data(line)) {
                    output.write(reply)
                }
            }
        }
    }

    /// One raw line in, one raw line out (or nothing for a notification).
    public func handleLine(_ line: Data) -> Data? {
        guard !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return encode(Self.errorResponse(id: .null, code: -32700, message: "parse error"))
        }
        return handle(message).flatMap(encode)
    }

    /// One message in, one response out — the pure core, the tests' seam.
    public func handle(_ message: JSONValue) -> JSONValue? {
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            guard let id else { return nil }   // a response or garbage without id: nothing to say
            return Self.errorResponse(id: id, code: -32600, message: "invalid request: no method")
        }
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            guard let id else { return nil }
            return Self.result(id: id, .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(Self.serverName),
                                       "version": .string("\(APIProtocol.version)")]),
                "instructions": .string(APIToolCatalog.instructions),
            ]))
        case "ping":
            guard let id else { return nil }
            return Self.result(id: id, .object([:]))
        case "tools/list":
            guard let id else { return nil }
            return Self.result(id: id, .object(["tools": .array(APIToolCatalog.all.map(Self.tool))]))
        case "tools/call":
            guard let id else { return nil }
            guard let name = params["name"]?.stringValue else {
                return Self.errorResponse(id: id, code: -32602, message: "tools/call needs a name")
            }
            guard let spec = APIToolCatalog.spec(named: name) else {
                return Self.errorResponse(id: id, code: -32602, message: "unknown tool \(name)")
            }
            let arguments = params["arguments"] ?? .object([:])
            do {
                let answer = try call(spec.method, arguments)
                return Self.result(id: id, Self.toolResult(text: Self.compact(answer), isError: false))
            } catch let error as APIError {
                return Self.result(id: id, Self.toolResult(text: "\(error.code.rawValue): \(error.message)",
                                                           isError: true))
            } catch {
                return Self.result(id: id, Self.toolResult(text: "loom: \(error)", isError: true))
            }
        default:
            if method.hasPrefix("notifications/") { return nil }
            guard let id else { return nil }
            return Self.errorResponse(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: - Shapes

    static func tool(_ spec: APIToolSpec) -> JSONValue {
        .object(["name": .string(spec.name),
                 "description": .string(spec.description),
                 "inputSchema": spec.inputSchema])
    }

    static func toolResult(text: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                 "isError": .bool(isError)])
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    static func compact(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private func encode(_ value: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(value) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
