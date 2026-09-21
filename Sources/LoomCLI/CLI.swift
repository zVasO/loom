import LoomAPI
import Foundation

/// The `loom` command: every API method as a verb, `docs` for the reference,
/// `mcp` for the server. Output is JSON on stdout — agents and humans both
/// read it — and every failure is one line on stderr with a non-zero exit.
public enum CLI {

    public enum Command: Equatable {
        case help
        case docs
        case mcp
        case version
        case sessionGet
        case sessionTitle(String)
        case badgeList
        case badgeCreate(name: String, colorHex: String?)
        case badgeSet([String])
        case badgeAdd(String)
        case badgeRemove(String)
        case badgeClear
        case sessions(includeArchived: Bool)
    }

    public struct Options: Equatable {
        public var socket: String?
        public var token: String?
        public var global = false
        public var sessionId: String?
        public var color: String?
        public var archived = false
        public init() {}
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownCommand(String)
        case missingArgument(String)
        case missingValue(String)

        public var description: String {
            switch self {
            case .unknownCommand(let words): return "unknown command: \(words) (see loom --help)"
            case .missingArgument(let what): return "missing \(what) (see loom --help)"
            case .missingValue(let flag): return "\(flag) needs a value"
            }
        }
    }

    public static let usage = """
    loom — talk to the Loom app from inside a session (or from anywhere, with --global)

    usage:
      loom version                          protocol and app versions
      loom session get                      your session: title, state, badges…
      loom session title <title>            rename your session
      loom badge list                       the badge catalog
      loom badge create <name> [--color #RRGGBB]
      loom badge set <name>…                replace your session's badges
      loom badge add <name>                 add one badge
      loom badge remove <name>              remove one badge
      loom badge clear                      remove them all
      loom sessions [--archived]            every session (needs --global)
      loom docs                             the API reference, as Markdown
      loom mcp                              serve the API as MCP tools on stdio

    options:
      --session <uuid>   which session (required with --global, forbidden otherwise)
      --socket <path>    Loom's socket (default: $LOOM_SOCKET, then Loom's support directory)
      --token <token>    the token to use (default: $LOOM_SESSION_TOKEN)
      --global           use Loom's global token (api-token in its support directory)
    """

    /// Words → command + options. Flags may appear anywhere.
    public static func parse(_ arguments: [String]) throws -> (Command, Options) {
        var options = Options()
        var words: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--help", "-h": return (.help, options)
            case "--global": options.global = true
            case "--archived": options.archived = true
            case "--socket", "--token", "--session", "--color":
                guard let value = iterator.next() else { throw ParseError.missingValue(argument) }
                switch argument {
                case "--socket": options.socket = value
                case "--token": options.token = value
                case "--session": options.sessionId = value
                default: options.color = value
                }
            default: words.append(argument)
            }
        }
        guard let first = words.first else { return (.help, options) }
        let rest = Array(words.dropFirst())
        switch (first, rest.first ?? "") {
        case ("help", _): return (.help, options)
        case ("docs", _): return (.docs, options)
        case ("mcp", _): return (.mcp, options)
        case ("version", _): return (.version, options)
        case ("sessions", _): return (.sessions(includeArchived: options.archived), options)
        case ("session", "get"): return (.sessionGet, options)
        case ("session", "title"):
            let title = rest.dropFirst().joined(separator: " ")
            guard !title.isEmpty else { throw ParseError.missingArgument("title") }
            return (.sessionTitle(title), options)
        case ("badge", "list"): return (.badgeList, options)
        case ("badge", "create"):
            guard let name = rest.dropFirst().first else { throw ParseError.missingArgument("badge name") }
            return (.badgeCreate(name: name, colorHex: options.color), options)
        case ("badge", "set"): return (.badgeSet(Array(rest.dropFirst())), options)
        case ("badge", "add"):
            guard let name = rest.dropFirst().first else { throw ParseError.missingArgument("badge name") }
            return (.badgeAdd(name), options)
        case ("badge", "remove"):
            guard let name = rest.dropFirst().first else { throw ParseError.missingArgument("badge name") }
            return (.badgeRemove(name), options)
        case ("badge", "clear"): return (.badgeClear, options)
        default: throw ParseError.unknownCommand(words.joined(separator: " "))
        }
    }

    /// The whole run: parse, connect, call, print. Returns the exit code.
    public static func run(_ arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           output: (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) },
                           error: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) -> Int32 {
        let parsed: (Command, Options)
        do {
            parsed = try parse(arguments)
        } catch {
            error("loom: \(error)\n")
            return 2
        }
        let (command, options) = parsed
        switch command {
        case .help:
            output(usage + "\n")
            return 0
        case .docs:
            output(APIToolCatalog.markdown())
            return 0
        default:
            break
        }
        let connection: Connection
        do {
            connection = try Connection.resolve(socket: options.socket, token: options.token,
                                                global: options.global, environment: environment)
        } catch {
            error("loom: \(error)\n")
            return 2
        }
        if case .mcp = command {
            let server = MCPServer(call: { method, params in
                try connection.client.call(method, params: params, as: JSONValue.self)
            })
            server.serve()
            return 0
        }
        do {
            let result = try execute(command, options: options, client: connection.client)
            output(pretty(result) + "\n")
            return 0
        } catch let apiError as APIError {
            error("loom: \(apiError.code.rawValue): \(apiError.message)\n")
            return 1
        } catch let clientError as APIClient.ClientError {
            error("loom: \(describe(clientError))\n")
            return 3
        } catch {
            error("loom: \(error)\n")
            return 1
        }
    }

    /// One command, one or two calls — badge add/remove read before they write.
    static func execute(_ command: Command, options: Options, client: APIClient) throws -> JSONValue {
        let session = options.sessionId
        switch command {
        case .version:
            return try client.call(.version, params: .object([:]))
        case .sessionGet:
            return try client.call(.sessionGet, APISessionRef(sessionId: session))
        case .sessionTitle(let title):
            return try client.call(.sessionSetTitle, APISetTitleParams(sessionId: session, title: title))
        case .badgeList:
            return try client.call(.badgeList, params: .object([:]))
        case .badgeCreate(let name, let colorHex):
            return try client.call(.badgeCreate, APICreateBadgeParams(name: name, colorHex: colorHex))
        case .badgeSet(let badges):
            return try client.call(.sessionSetBadges, APISetBadgesParams(sessionId: session, badges: badges))
        case .badgeClear:
            return try client.call(.sessionSetBadges, APISetBadgesParams(sessionId: session, badges: []))
        case .badgeAdd(let name):
            let current: APISession = try client.call(.sessionGet, APISessionRef(sessionId: session))
            let badges = current.badges.contains(name) ? current.badges : current.badges + [name]
            return try client.call(.sessionSetBadges, APISetBadgesParams(sessionId: session, badges: badges))
        case .badgeRemove(let name):
            let current: APISession = try client.call(.sessionGet, APISessionRef(sessionId: session))
            return try client.call(.sessionSetBadges,
                                   APISetBadgesParams(sessionId: session,
                                                      badges: current.badges.filter { $0 != name }))
        case .sessions(let includeArchived):
            return try client.call(.sessionsList,
                                   APISessionsListParams(includeArchived: includeArchived ? true : nil))
        case .help, .docs, .mcp:
            return .null   // handled before execute
        }
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func describe(_ error: APIClient.ClientError) -> String {
        switch error {
        case .connectionFailed(let errno):
            return "cannot reach Loom's socket (errno \(errno)) — is Loom running?"
        case .rejected:
            return "Loom closed the connection: the token is not known to this Loom"
        case .timedOut:
            return "Loom did not answer in time"
        case .malformedResponse:
            return "Loom answered something this loom does not understand — versions out of step?"
        case .writeFailed(let errno):
            return "write failed (errno \(errno))"
        case .socketPathTooLong:
            return "the socket path is too long for a Unix socket"
        }
    }
}
