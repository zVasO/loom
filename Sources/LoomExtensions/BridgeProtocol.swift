import Foundation
import LoomAPI

// The bridge between an extension's page and Loom (ADR-0011): one request,
// one response, carried as JSON text through WebKit's reply-capable message
// handler — `window.loom` posts `{id, method, params}`, Loom answers
// `{id, result}` or `{id, error: {code, message}}`. Its own contract, versioned
// by the manifest's `loomApi`: it shares the agents API's session projection,
// never its envelope, so neither protocol moves when the other does.

public struct BridgeRequest: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var params: JSONValue

    public init(id: String, method: String, params: JSONValue = .object([:])) {
        self.id = id
        self.method = method
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        // A request without params is a request with none; `null` too.
        let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        self.params = (params == nil || params == .null) ? .object([:]) : params!
    }

    public func decodeParams<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        do {
            return try params.decode(type)
        } catch {
            throw BridgeError(.invalidParams, "\(method): the parameters do not have the expected shape")
        }
    }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public var id: String
    public var result: JSONValue?
    public var error: BridgeError?

    public init(id: String, result: JSONValue? = nil, error: BridgeError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    public static func ok<T: Encodable>(_ id: String, _ value: T) -> BridgeResponse {
        do {
            return BridgeResponse(id: id, result: try JSONValue.from(value))
        } catch {
            return BridgeResponse(id: id, error: BridgeError(.internalError, "the result could not be encoded"))
        }
    }

    public static func failure(_ id: String, _ error: BridgeError) -> BridgeResponse {
        BridgeResponse(id: id, error: error)
    }

    /// The JSON text handed back to the page. Never fails: a response that
    /// cannot be encoded becomes an internal error that can.
    public var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) {
            return text
        }
        let fallback = BridgeResponse(id: id, error: BridgeError(.internalError, "the response could not be encoded"))
        if let data = try? encoder.encode(fallback), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return #"{"error":{"code":"internalError","message":"encoding failed"},"id":""}"#
    }
}

public struct BridgeError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case invalidRequest, unknownMethod, invalidParams, forbidden, notFound, conflict
        /// The remote host could not be reached, or answered with no response.
        case network
        /// A body, a stored value or a secret over its cap.
        case tooLarge
        case internalError
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

/// Every method the bridge answers, and the permission each one needs. The
/// extension's own storage and secrets need none: they reach nothing else.
public enum BridgeMethod: String, CaseIterable, Sendable {
    case info = "loom.info"
    case projectsList = "projects.list"
    case sessionsList = "sessions.list"
    case sessionsGet = "sessions.get"
    case sessionsOpen = "sessions.open"
    case sessionsLaunch = "sessions.launch"
    case httpFetch = "http.fetch"
    case secretsGet = "secrets.get"
    case secretsSet = "secrets.set"
    case secretsDelete = "secrets.delete"
    case storageGet = "storage.get"
    case storageSet = "storage.set"
    case storageDelete = "storage.delete"
    case openExternal = "ui.openExternal"

    public enum Requirement: Equatable, Sendable, CustomStringConvertible {
        case sessions(ExtensionPermissions.SessionAccess)
        case projects(ExtensionPermissions.ProjectAccess)
        case network

        public var description: String {
            switch self {
            case .sessions(let access): return "sessions: \(access.rawValue)"
            case .projects(let access): return "projects: \(access.rawValue)"
            case .network: return "network"
            }
        }
    }

    public var requirement: Requirement? {
        switch self {
        case .info, .secretsGet, .secretsSet, .secretsDelete,
             .storageGet, .storageSet, .storageDelete, .openExternal:
            return nil
        case .projectsList: return .projects(.read)
        case .sessionsList, .sessionsGet, .sessionsOpen: return .sessions(.read)
        case .sessionsLaunch: return .sessions(.launch)
        case .httpFetch: return .network
        }
    }
}

// MARK: - Models

/// The app's current theme: the 16 palette tokens by name (`#RRGGBB`), which
/// the SDK turns into `--loom-<token>` CSS variables.
public struct BridgeTheme: Codable, Equatable, Sendable {
    public var isLight: Bool
    public var tokens: [String: String]
    public init(isLight: Bool, tokens: [String: String]) {
        self.isLight = isLight
        self.tokens = tokens
    }
}

/// `loom.info`.
public struct BridgeInfo: Codable, Equatable, Sendable {
    public var loomApi: Int
    public var appVersion: String
    public var extensionId: String
    public var theme: BridgeTheme
    public init(loomApi: Int, appVersion: String, extensionId: String, theme: BridgeTheme) {
        self.loomApi = loomApi
        self.appVersion = appVersion
        self.extensionId = extensionId
        self.theme = theme
    }
}

/// A project as an extension sees it: which, and its name — never its path.
public struct BridgeProject: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct BridgeProjectsList: Codable, Equatable, Sendable {
    public var projects: [BridgeProject]
    public init(projects: [BridgeProject]) { self.projects = projects }
}

public struct BridgeSessionsListParams: Codable, Equatable, Sendable {
    public var includeArchived: Bool?
    public init(includeArchived: Bool? = nil) { self.includeArchived = includeArchived }
}

public struct BridgeSessionsList: Codable, Equatable, Sendable {
    public var sessions: [APISession]
    public init(sessions: [APISession]) { self.sessions = sessions }
}

public struct BridgeSessionRef: Codable, Equatable, Sendable {
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

/// `sessions.launch`: what the extension proposes. The user sees all of it in
/// Loom's confirmation sheet, edits it, and launches — or not.
public struct BridgeLaunchParams: Codable, Equatable, Sendable {
    public var projectId: String?
    public var prompt: String
    public var title: String?
    public var badges: [String]?
    /// `"worktree"` or `"folder"`; absent means the project's default.
    public var placement: String?

    public init(projectId: String? = nil, prompt: String, title: String? = nil,
                badges: [String]? = nil, placement: String? = nil) {
        self.projectId = projectId
        self.prompt = prompt
        self.title = title
        self.badges = badges
        self.placement = placement
    }

    public static let maxPromptLength = 100_000
    public static let maxBadges = 8
    public static let maxBadgeLength = 40
    public static let maxTitleLength = 200

    /// Checks the proposal before any sheet opens.
    public func validate() throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BridgeError(.invalidParams, "sessions.launch needs a prompt")
        }
        guard prompt.count <= Self.maxPromptLength else {
            throw BridgeError(.tooLarge, "the prompt is over \(Self.maxPromptLength) characters")
        }
        if let title, title.count > Self.maxTitleLength {
            throw BridgeError(.invalidParams, "the title is over \(Self.maxTitleLength) characters")
        }
        if let badges {
            guard badges.count <= Self.maxBadges,
                  badges.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty
                                      && $0.count <= Self.maxBadgeLength })
            else {
                throw BridgeError(.invalidParams,
                                  "at most \(Self.maxBadges) badges of 1 to \(Self.maxBadgeLength) characters")
            }
        }
        if let placement, placement != "worktree", placement != "folder" {
            throw BridgeError(.invalidParams, "placement is \"worktree\" or \"folder\"")
        }
        if let projectId, UUID(uuidString: projectId) == nil {
            throw BridgeError(.invalidParams, "projectId is not a project id")
        }
    }
}

public struct BridgeLaunchResult: Codable, Equatable, Sendable {
    public var launched: Bool
    public var sessionId: String?
    public init(launched: Bool, sessionId: String? = nil) {
        self.launched = launched
        self.sessionId = sessionId
    }
}

public struct BridgeKeyParams: Codable, Equatable, Sendable {
    public var key: String
    public init(key: String) { self.key = key }
}

public struct BridgeSecretSetParams: Codable, Equatable, Sendable {
    public var key: String
    public var value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct BridgeStorageSetParams: Codable, Equatable, Sendable {
    public var key: String
    public var value: JSONValue
    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
    }
}

public struct BridgeURLParams: Codable, Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}

/// The empty success: `{ "ok": true }`.
public struct BridgeOK: Codable, Equatable, Sendable {
    public var ok: Bool
    public init() { ok = true }
}

// MARK: - Events

/// What Loom pushes to a page, unasked: `window.__loomEmit` hands it to the
/// listeners `loom.on(name, …)` registered.
public struct BridgeEvent: Codable, Equatable, Sendable {
    public var name: String
    public var payload: JSONValue

    public init(name: String, payload: JSONValue) {
        self.name = name
        self.payload = payload
    }

    public static let themeChangedName = "theme.changed"
    public static let sessionsChangedName = "sessions.changed"
    public static let sessionStateChangedName = "session.stateChanged"
    public static let commandName = "command"

    public static func themeChanged(_ theme: BridgeTheme) -> BridgeEvent {
        BridgeEvent(name: themeChangedName, payload: (try? JSONValue.from(theme)) ?? .null)
    }

    public static func sessionsChanged(_ sessions: [APISession]) -> BridgeEvent {
        BridgeEvent(name: sessionsChangedName,
                    payload: (try? JSONValue.from(BridgeSessionsList(sessions: sessions))) ?? .null)
    }

    public static func sessionStateChanged(sessionId: String, state: String,
                                           previous: String?) -> BridgeEvent {
        var payload: [String: JSONValue] = ["sessionId": .string(sessionId), "state": .string(state)]
        payload["previous"] = previous.map(JSONValue.string) ?? .null
        return BridgeEvent(name: sessionStateChangedName, payload: .object(payload))
    }

    public static func command(_ id: String) -> BridgeEvent {
        BridgeEvent(name: commandName, payload: .object(["id": .string(id)]))
    }

    /// The permission a page needs to hear this event: session events carry
    /// what `sessions.list` would, and are held to the same grant.
    public var requirement: BridgeMethod.Requirement? {
        switch name {
        case Self.sessionsChangedName, Self.sessionStateChangedName: return .sessions(.read)
        default: return nil
        }
    }
}
