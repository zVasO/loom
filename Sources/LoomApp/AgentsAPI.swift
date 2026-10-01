import LoomAPI
import LoomCore
import LoomPersistence
import Foundation

// The app's side of the agents API (ADR-0010): the methods, answered on the
// main actor with the same calls the UI makes. Metadata — a title, a list of
// badges, the catalog — and the session's own browser (ADR-0014); never a
// state: the reducer has four sources and the API is not one.

extension AppModel {

    /// The global token: one per support directory, generated on first launch,
    /// readable by the user alone (0600). Whoever holds it sees every session.
    static let apiTokenFileName = "api-token"

    static func loadOrCreateAPIToken(in directory: URL) -> String? {
        let url = directory.appendingPathComponent(apiTokenFileName)
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        let token = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "").lowercased()
        let created = FileManager.default.createFile(
            atPath: url.path, contents: Data((token + "\n").utf8),
            attributes: [.posixPermissions: 0o600])
        return created ? token : nil
    }

    /// One request, one response — errors included, never a throw past here.
    /// Async: a method may wait on something slow (ADR-0014's browser), on
    /// the main actor without blocking it.
    func handleAPIRequest(_ scope: APIScope, _ request: APIRequest) async -> APIResponse {
        guard let method = APIMethod(rawValue: request.method) else {
            return APIResponse(id: request.id, error: APIError(
                code: .unknownMethod, message: "unknown method \(request.method)"))
        }
        if method.requiresGlobalScope, scope != .global {
            return APIResponse(id: request.id, error: APIError(
                code: .forbidden, message: "\(method.rawValue) needs the global token"))
        }
        if !method.allowsGlobalScope, scope == .global {
            return APIResponse(id: request.id, error: APIError(
                code: .forbidden, message: "\(method.rawValue) answers the session's own token only"))
        }
        do {
            switch method {
            case .version:
                return .ok(request.id, APIVersion(
                    protocolVersion: APIProtocol.version,
                    app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
            case .sessionsList:
                let params = try request.decodeParams(APISessionsListParams.self)
                let listed = allRecords
                    .filter { params.includeArchived == true || $0.state != .archived }
                    .map { apiSession(record: $0) }
                return .ok(request.id, APISessionsListResult(sessions: listed))
            case .sessionGet:
                let params = try request.decodeParams(APISessionRef.self)
                let id = try targetSession(scope, named: params.sessionId)
                return .ok(request.id, try apiSession(id))
            case .sessionSetTitle:
                let params = try request.decodeParams(APISetTitleParams.self)
                let id = try targetSession(scope, named: params.sessionId)
                // One line, printable, bounded: the title is also a
                // notification's title (APILimits).
                let title = APILimits.sanitizedTitle(params.title)
                guard !title.isEmpty else {
                    throw APIError(code: .invalidParams, message: "title must not be empty")
                }
                renameSession(id, to: title)
                return .ok(request.id, try apiSession(id))
            case .sessionSetBadges:
                let params = try request.decodeParams(APISetBadgesParams.self)
                let id = try targetSession(scope, named: params.sessionId)
                // A PR session's "PR #n" is Loom's (it files the session under
                // code review): the agent may set badges around it, never take
                // it off — nor give itself one, which would then stick.
                let kept = badges(of: id).filter { Self.wearsPRBadge([$0]) }
                let added = params.badges.filter { !kept.contains($0) }
                if added.contains(where: { Self.wearsPRBadge([$0]) }) {
                    throw APIError(code: .invalidParams,
                                   message: "\"PR #n\" badges are Loom's: the PR tab gives them")
                }
                let merged = kept + added
                if let problem = APILimits.badgeProblem(merged) {
                    throw APIError(code: .invalidParams, message: problem)
                }
                setBadges(merged, for: id)
                return .ok(request.id, try apiSession(id))
            case .browserNavigate, .browserNavigateBack, .browserSnapshot, .browserClick, .browserType,
                 .browserSelectOption, .browserHover, .browserPressKey, .browserWaitFor, .browserScreenshot,
                 .browserConsole, .browserNetwork, .browserEvaluate, .browserHandleDialog, .browserTabs,
                 .browserClose, .browserFillForm, .browserFileUpload, .browserResize:
                return try await handleBrowserRequest(method, request, scope: scope)
            case .badgeList:
                return .ok(request.id, APIBadgeListResult(badges: apiBadges))
            case .badgeCreate:
                let params = try request.decodeParams(APICreateBadgeParams.self)
                let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    throw APIError(code: .invalidParams, message: "name must not be empty")
                }
                guard name.count <= APILimits.badgeNameMaxLength,
                      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw APIError(code: .invalidParams,
                                   message: "a badge name is one short line (\(APILimits.badgeNameMaxLength) characters at most)")
                }
                guard badgeDefinitions.count < APILimits.catalogMaxCount else {
                    throw APIError(code: .conflict,
                                   message: "the badge catalog is full (\(APILimits.catalogMaxCount)): reuse a badge")
                }
                let color = params.colorHex ?? Self.defaultBadgeColorHex
                guard APIBadge.isValidColor(color) else {
                    throw APIError(code: .invalidParams, message: "colorHex must be #RRGGBB")
                }
                guard addBadgeDefinition(BadgeDefinition(name: name, colorHex: color)) else {
                    throw APIError(code: .conflict, message: "badge \(name) already exists")
                }
                return .ok(request.id, APIBadgeListResult(badges: apiBadges))
            }
        } catch let error as APIError {
            return APIResponse(id: request.id, error: error)
        } catch {
            return APIResponse(id: request.id, error: APIError(
                code: .internalError, message: "\(error)"))
        }
    }

    // MARK: - Scope

    /// The session a request means: its own under a session token (a name
    /// that differs is forbidden, not "not found" — the token never learns
    /// whether the other exists); a required name under the global token.
    func targetSession(_ scope: APIScope, named sessionId: String?) throws -> SessionID {
        switch scope {
        case .session(let own):
            if let sessionId, sessionId.lowercased() != own.rawValue.uuidString.lowercased() {
                throw APIError(code: .forbidden, message: "a session token reaches its own session only")
            }
            return own
        case .global:
            guard let sessionId else {
                throw APIError(code: .invalidParams, message: "sessionId is required under the global token")
            }
            guard let uuid = UUID(uuidString: sessionId) else {
                throw APIError(code: .invalidParams, message: "sessionId is not a UUID")
            }
            return SessionID(uuid)
        }
    }

    // MARK: - Projections

    private static let isoFormatter = ISO8601DateFormatter()
    private static let defaultBadgeColorHex = "#86868E"

    private var apiBadges: [APIBadge] {
        badgeDefinitions.map { APIBadge(name: $0.name, colorHex: $0.colorHex) }
    }

    /// A session as the API shows it: the live item's title, state and badges
    /// win over the record's — the record is what the base last heard.
    func apiSession(_ id: SessionID) throws -> APISession {
        guard let record = allRecords.first(where: { $0.id == id }) else {
            throw APIError(code: .notFound, message: "no session \(id.rawValue.uuidString)")
        }
        return apiSession(record: record)
    }

    func apiSession(record: SessionRecord) -> APISession {
        let live = sessions.first { $0.id == record.id }
        return APISession(id: record.id.rawValue.uuidString,
                          title: live?.title ?? record.title,
                          state: (live?.state ?? record.state).rawValue,
                          projectID: record.projectID?.rawValue.uuidString,
                          branch: record.branch,
                          worktreePath: record.worktreePath,
                          badges: live?.badges ?? record.badges,
                          createdAt: Self.isoFormatter.string(from: record.createdAt))
    }
}
