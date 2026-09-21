import Foundation

// The catalog as clients present it: one tool per method, with the words
// and the schema an agent reads. This is the documentation — the MCP server
// lists it, `loom docs` prints it, and neither adds a word of its own.

public struct APIToolSpec: Sendable, Equatable {
    public var method: APIMethod
    /// The MCP tool name: `[a-zA-Z0-9_-]`, so dots become underscores.
    public var name: String
    public var description: String
    /// JSON Schema of the parameters — the method's params, verbatim.
    public var inputSchema: JSONValue
    /// How the CLI spells it, for the reference.
    public var cliUsage: String
}

public enum APIToolCatalog {

    public static let all: [APIToolSpec] = [
        APIToolSpec(
            method: .version, name: "loom_version",
            description: "Loom's protocol and app versions. A cheap way to check the socket answers.",
            inputSchema: object([:]),
            cliUsage: "loom version"),
        APIToolSpec(
            method: .sessionGet, name: "loom_session_get",
            description: "The session you run in: title, state, branch, worktree path, badges. "
                + "Under a session token, sessionId is yours and may be omitted.",
            inputSchema: object(["sessionId": sessionIdProperty]),
            cliUsage: "loom session get"),
        APIToolSpec(
            method: .sessionSetTitle, name: "loom_session_set_title",
            description: "Renames the session in Loom's sidebar and Mission Control. "
                + "Use it once the task is clear enough to name.",
            inputSchema: object(["sessionId": sessionIdProperty,
                                 "title": string("The new title, non-empty.")],
                                required: ["title"]),
            cliUsage: "loom session title <title>"),
        APIToolSpec(
            method: .sessionSetBadges, name: "loom_session_set_badges",
            description: "Replaces the session's badges with this list, in this order; an empty list clears them. "
                + "Names should come from loom_badge_list — an unknown name shows in a muted color.",
            inputSchema: object(["sessionId": sessionIdProperty,
                                 "badges": .object(["type": .string("array"),
                                                    "items": .object(["type": .string("string")]),
                                                    "description": .string("Badge names, in display order.")])],
                                required: ["badges"]),
            cliUsage: "loom badge set <name>… | loom badge add <name> | loom badge remove <name> | loom badge clear"),
        APIToolSpec(
            method: .badgeList, name: "loom_badge_list",
            description: "The badge catalog: every name a session may wear, with its color.",
            inputSchema: object([:]),
            cliUsage: "loom badge list"),
        APIToolSpec(
            method: .badgeCreate, name: "loom_badge_create",
            description: "Adds a badge to the catalog. Fails with `conflict` when the name exists. "
                + "Prefer an existing badge over a new one.",
            inputSchema: object(["name": string("The badge name, short and lowercase by convention."),
                                 "colorHex": string("#RRGGBB; Loom's muted default when omitted.")],
                                required: ["name"]),
            cliUsage: "loom badge create <name> [--color #RRGGBB]"),
        APIToolSpec(
            method: .sessionsList, name: "loom_sessions_list",
            description: "Every session Loom knows, archived ones on request. Needs the global token: "
                + "a session token is refused with `forbidden`.",
            inputSchema: object(["includeArchived": .object(["type": .string("boolean"),
                                                             "description": .string("Archived sessions too.")])]),
            cliUsage: "loom sessions [--archived] (global token)"),
    ]

    public static func spec(for method: APIMethod) -> APIToolSpec {
        all.first { $0.method == method }!   // every method is listed: a missing one is a programming error
    }

    public static func spec(named name: String) -> APIToolSpec? {
        all.first { $0.name == name }
    }

    /// What an agent should know before its first call — the MCP `instructions`
    /// and the top of `loom docs`.
    public static let instructions = """
    You are running inside Loom, a macOS app that hosts coding-agent sessions. \
    Loom shows each session as a card with a title and badges. You may rename your \
    own session and set its badges so the person supervising sees where you are \
    (for instance `review` when you are ready for one). You cannot change your \
    session's state, start or stop sessions, or touch other sessions with your \
    own token. Prefer badges from the catalog over creating new ones.
    """

    /// The reference, as Markdown — what `loom docs` prints.
    public static func markdown() -> String {
        var lines = ["# Loom agents API", "", instructions, "",
                     "Every call is one JSON request over Loom's Unix socket (`LOOM_SOCKET`), "
                     + "authenticated by a token (`LOOM_SESSION_TOKEN` for your session; "
                     + "the global token in Loom's `api-token` file for every session). "
                     + "Protocol version \(APIProtocol.version).", ""]
        for spec in all {
            lines.append("## `\(spec.method.rawValue)`")
            lines.append("")
            lines.append(spec.description)
            lines.append("")
            lines.append("- MCP tool: `\(spec.name)`")
            lines.append("- CLI: `\(spec.cliUsage)`")
            if let properties = spec.inputSchema["properties"], case .object(let fields) = properties, !fields.isEmpty {
                let required = requiredNames(of: spec.inputSchema)
                lines.append("- Parameters:")
                for key in fields.keys.sorted() {
                    let field = fields[key]!
                    let kind = field["type"]?.stringValue ?? "any"
                    let text = field["description"]?.stringValue ?? ""
                    let mark = required.contains(key) ? " (required)" : ""
                    lines.append("  - `\(key)` — \(kind)\(mark). \(text)")
                }
            }
            lines.append("")
        }
        lines.append("Errors: `invalidRequest`, `unknownMethod`, `invalidParams`, `forbidden`, `notFound`, `conflict`, `internalError`.")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Schema helpers

    private static let sessionIdProperty = string(
        "UUID of the session. Optional under a session token (yours); required under the global token.")

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    private static func requiredNames(of schema: JSONValue) -> Set<String> {
        guard case .array(let names)? = schema["required"] else { return [] }
        return Set(names.compactMap(\.stringValue))
    }
}
