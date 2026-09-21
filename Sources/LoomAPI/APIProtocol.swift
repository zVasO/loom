import LoomCore
import Foundation

// The agents API (ADR-0010): requests with a response, over the hooks socket
// of ADR-0005. One JSON line each way. This file is the wire contract; the
// app serves it, the CLI and the MCP server consume it, and nothing in here
// depends on either side.
//
// Request line:  {"token": "…", "request": {"id": "…", "method": "…", "params": {…}}}
// Response line: {"id": "…", "result": {…}}  |  {"id": "…", "error": {"code": "…", "message": "…"}}
//
// A line carrying `payload` instead of `request` is a hook (ADR-0005) and
// takes the other path — the same server serves both, `loom-hook` unchanged.

public enum APIProtocol {
    /// Bumped on any change a client could observe: a method's shape, an
    /// error code, the envelope. `loom.version` answers it.
    public static let version = 1

    /// Environment of every agent Loom hosts: where the socket is and the
    /// token that names its own session. The CLI reads both.
    public static let socketEnvironmentKey = "LOOM_SOCKET"
    public static let sessionTokenEnvironmentKey = "LOOM_SESSION_TOKEN"
}

/// Who is asking — decided by the token the server saw, never by the request.
public enum APIScope: Sendable, Equatable {
    /// The session's own token: this session, nothing else.
    case session(SessionID)
    /// The app's global token (a 0600 file): every session.
    case global
}

/// Every method the API answers, with the scope it demands. A method absent
/// from here does not exist — `unknownMethod` is the answer.
public enum APIMethod: String, CaseIterable, Sendable {
    case version = "loom.version"
    case sessionsList = "sessions.list"
    case sessionGet = "session.get"
    case sessionSetTitle = "session.setTitle"
    case sessionSetBadges = "session.setBadges"
    case badgeList = "badge.list"
    case badgeCreate = "badge.create"

    /// Listing every session is the orchestrator's view: a session token,
    /// scoped to itself, never sees its neighbours.
    public var requiresGlobalScope: Bool {
        switch self {
        case .sessionsList: return true
        default: return false
        }
    }
}

public struct APIRequest: Codable, Equatable, Sendable {
    /// Client-chosen; echoed on the response so a client can match them.
    public var id: String
    public var method: String
    public var params: JSONValue

    public init(id: String = UUID().uuidString, method: APIMethod, params: JSONValue = .object([:])) {
        self.id = id
        self.method = method.rawValue
        self.params = params
    }

    public init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case id, method, params }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params) ?? .object([:])
    }

    /// The typed parameters of a method, or `invalidParams`.
    public func decodeParams<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        do {
            return try params.decode(type)
        } catch {
            throw APIError(code: .invalidParams, message: "\(error)")
        }
    }
}

public struct APIResponse: Codable, Equatable, Sendable {
    public var id: String
    public var result: JSONValue?
    public var error: APIError?

    public init(id: String, result: JSONValue) {
        self.id = id
        self.result = result
    }

    public init(id: String, error: APIError) {
        self.id = id
        self.error = error
    }

    /// A typed result, from a model — the server's way to answer.
    public static func ok<T: Encodable>(_ id: String, _ value: T) -> APIResponse {
        do {
            return APIResponse(id: id, result: try JSONValue.from(value))
        } catch {
            return APIResponse(id: id, error: APIError(code: .internalError, message: "\(error)"))
        }
    }
}

public struct APIError: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        /// The line was not a request the server could read.
        case invalidRequest
        case unknownMethod
        case invalidParams
        /// The token's scope does not reach what the request names.
        case forbidden
        case notFound
        /// The write collides with what exists (a badge name already taken).
        case conflict
        case internalError
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

/// The wire envelopes, as the server reads them and the client writes them.
public enum APIEnvelope {
    public static let tokenKey = "token"
    public static let requestKey = "request"
    public static let hookPayloadKey = "payload"

    /// One request line, newline included.
    public static func requestLine(token: String, request: APIRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Wrapper(token: token, request: request))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// One response line, newline included.
    public static func responseLine(_ response: APIResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(response)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func decodeResponse(_ line: Data) throws -> APIResponse {
        try JSONDecoder().decode(APIResponse.self, from: line)
    }

    private struct Wrapper: Encodable {
        var token: String
        var request: APIRequest
    }
}
