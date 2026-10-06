import Foundation

// The catalog as clients present it: one tool per method, with the words
// and the schema an agent reads. This is the documentation — the MCP server
// lists it, `loom docs` prints it, and neither adds a word of its own.

public struct APIToolSpec: Sendable, Equatable {
    /// How a result reaches the agent.
    public enum ResultFormat: Sendable, Equatable {
        /// The method's JSON, compact.
        case json
        /// An `APIToolContent`: Markdown shown as is, an image as an image.
        case content
    }

    public var method: APIMethod
    /// The MCP tool name: `[a-zA-Z0-9_-]`, so dots become underscores.
    public var name: String
    public var description: String
    /// JSON Schema of the parameters — the method's params, verbatim.
    public var inputSchema: JSONValue
    /// How the CLI spells it, for the reference.
    public var cliUsage: String
    public var resultFormat: ResultFormat = .json
    /// Claude Code runs it without asking when Loom pre-approves its tools
    /// (Settings). No default: every tool added must decide — one that
    /// destroys or launches anything must not be.
    public var preapprovable: Bool
}

public enum APIToolCatalog {

    /// Every tool, worded for the WebKit engine — what `loom docs` prints.
    public static let all: [APIToolSpec] = webkitCatalog

    /// Every tool a session on `engine` may list.
    public static func all(engine: APIBrowserEngine) -> [APIToolSpec] {
        switch engine {
        case .webkit: return webkitCatalog
        case .chromium: return chromiumCatalog
        }
    }

    private static let webkitCatalog = sessionTools + browserTools(engine: .webkit)
    private static let chromiumCatalog = sessionTools + browserTools(engine: .chromium)

    static let sessionTools: [APIToolSpec] = [
        APIToolSpec(
            method: .version, name: "loom_version",
            description: "Loom's protocol and app versions. A cheap way to check the socket answers.",
            inputSchema: object([:]),
            cliUsage: "loom version", preapprovable: true),
        APIToolSpec(
            method: .sessionGet, name: "loom_session_get",
            description: "The session you run in: title, state, branch, worktree path, badges. "
                + "Under a session token, sessionId is yours and may be omitted.",
            inputSchema: object(["sessionId": sessionIdProperty]),
            cliUsage: "loom session get", preapprovable: true),
        APIToolSpec(
            method: .sessionSetTitle, name: "loom_session_set_title",
            description: "Renames the session in Loom's sidebar and Mission Control. "
                + "Use it once the task is clear enough to name.",
            inputSchema: object(["sessionId": sessionIdProperty,
                                 "title": string("The new title, non-empty.")],
                                required: ["title"]),
            cliUsage: "loom session title <title>", preapprovable: true),
        APIToolSpec(
            method: .sessionSetBadges, name: "loom_session_set_badges",
            description: "Replaces the session's badges with this list, in this order; an empty list clears them. "
                + "Names should come from loom_badge_list — an unknown name shows in a muted color.",
            inputSchema: object(["sessionId": sessionIdProperty,
                                 "badges": .object(["type": .string("array"),
                                                    "items": .object(["type": .string("string")]),
                                                    "description": .string("Badge names, in display order.")])],
                                required: ["badges"]),
            cliUsage: "loom badge set <name>… | loom badge add <name> | loom badge remove <name> | loom badge clear", preapprovable: true),
        APIToolSpec(
            method: .badgeList, name: "loom_badge_list",
            description: "The badge catalog: every name a session may wear, with its color.",
            inputSchema: object([:]),
            cliUsage: "loom badge list", preapprovable: true),
        APIToolSpec(
            method: .badgeCreate, name: "loom_badge_create",
            description: "Adds a badge to the catalog. Fails with `conflict` when the name exists. "
                + "Prefer an existing badge over a new one.",
            inputSchema: object(["name": string("The badge name, short and lowercase by convention."),
                                 "colorHex": string("#RRGGBB; Loom's muted default when omitted.")],
                                required: ["name"]),
            cliUsage: "loom badge create <name> [--color #RRGGBB]", preapprovable: true),
        APIToolSpec(
            method: .sessionsList, name: "loom_sessions_list",
            description: "Every session Loom knows, archived ones on request. Needs the global token: "
                + "a session token is refused with `forbidden`.",
            inputSchema: object(["includeArchived": .object(["type": .string("boolean"),
                                                             "description": .string("Archived sessions too.")])]),
            cliUsage: "loom sessions [--archived] (global token)", preapprovable: true),
    ]

    /// The session's own browser (ADR-0014). Every tool answers Markdown in
    /// Playwright MCP's sections (### Page, ### Snapshot…); the actions also
    /// answer the page's new snapshot, so one call both acts and shows.
    static func browserTools(engine: APIBrowserEngine) -> [APIToolSpec] {
        let chromium = engine == .chromium
        return [
            browser(.browserNavigate, "browser_navigate",
                    "Navigate your browser to a URL and answer the page's snapshot. A bare host:port on "
                    + "localhost or 127.0.0.1 opens in http (a dev server); other bare hosts in https. "
                    + "Only http(s) — no file:, data: or javascript:.",
                    ["url": string("The address, e.g. localhost:5173 or https://example.com/login.")],
                    required: ["url"], cli: #"loom browser navigate localhost:5173"#),
            browser(.browserNavigateBack, "browser_navigate_back", "Go back to the previous page.",
                    [:], cli: "loom browser navigate_back"),
            browser(.browserSnapshot, "browser_snapshot",
                    "Capture an accessibility snapshot of the current page: its elements as YAML, each "
                    + "interactive one with a ref (e12) the other tools take. Better than a screenshot "
                    + "for acting. A ref is valid until the next snapshot; refs of an element stay the "
                    + "same while its role and name do. Pass a target to snapshot one element's subtree.",
                    ["target": targetProperty(optional: true), "ref": refAlias,
                     "depth": number("How many levels deep to describe (all by default).")],
                    cli: "loom browser snapshot"),
            browser(.browserClick, "browser_click",
                    "Click an element: waits until it is visible, enabled, steady and not covered (5 s), "
                    + "then clicks its center. Answers the new snapshot, or the dialog the click opened.",
                    ["element": elementProperty, "target": targetProperty(optional: false), "ref": refAlias,
                     "doubleClick": boolean("A double click."),
                     "button": enumeration(["left", "right", "middle"], "The mouse button, left by default."),
                     "modifiers": array(enumeration(["Alt", "Control", "ControlOrMeta", "Meta", "Shift"], "A key held."),
                                        "Keys held during the click.")],
                    cli: #"loom browser click e12"#),
            browser(.browserType, "browser_type",
                    "Replace an editable field's text, as typing would (React and Vue see it), "
                    + "then optionally press Enter.",
                    ["element": elementProperty, "target": targetProperty(optional: false), "ref": refAlias,
                     "text": string("The text the field ends up with."),
                     "submit": boolean("Press Enter afterwards (submits a form)."),
                     "slowly": boolean("Type one key at a time, for handlers that watch keys "
                                       + "(autocomplete); 200 characters at most. Off by default.")],
                    required: ["text"], cli: #"loom browser type '{"target":"e5","text":"milk","submit":true}'"#),
            browser(.browserSelectOption, "browser_select_option",
                    "Choose options of a <select>, by value or by visible label. For a custom dropdown, "
                    + "click it, then click the option.",
                    ["element": elementProperty, "target": targetProperty(optional: false), "ref": refAlias,
                     "values": array(.object(["type": .string("string")]), "Values or labels; several for a multiple select.")],
                    required: ["values"], cli: #"loom browser select_option '{"target":"e7","values":["Blue"]}'"#),
            browser(.browserHover, "browser_hover",
                    chromium
                        ? "Move the pointer over an element and leave it there: a real pointer, so CSS :hover "
                            + "applies and JavaScript hover handlers run."
                        : "Move the pointer over an element (JavaScript hover handlers run; CSS :hover does not).",
                    ["element": elementProperty, "target": targetProperty(optional: false), "ref": refAlias],
                    cli: "loom browser hover e9"),
            browser(.browserPressKey, "browser_press_key",
                    "Press a key in the focused element: Enter, Tab, Escape, Backspace, Arrow keys, a "
                    + "character, with modifiers (Shift+Tab, ControlOrMeta+a).",
                    ["key": string("The key, Playwright's syntax.")], required: ["key"],
                    cli: "loom browser press_key Enter"),
            browser(.browserWaitFor, "browser_wait_for",
                    "Wait for some time, or for a text to appear or disappear on the page (30 s at most).",
                    ["time": number("Seconds to wait."), "text": string("Wait until this text is visible."),
                     "textGone": string("Wait until this text is gone."),
                     "timeout": number("Seconds to wait for the text, 10 by default.")],
                    cli: #"loom browser wait_for '{"text":"Saved"}'"#),
            browser(.browserScreenshot, "browser_take_screenshot",
                    "Take a screenshot of the visible page, of one element, or of the whole page. For "
                    + "looking, not for acting: use browser_snapshot to act.",
                    ["element": elementProperty, "target": targetProperty(optional: true), "ref": refAlias,
                     "type": enumeration(["png", "jpeg"], "The format, png by default."),
                     "fullPage": boolean("The whole scrollable page"
                                         + (chromium ? " (captured in one pass)" : " (scrolled through, then put back)")
                                         + ", not just what is visible. Not with a target.")],
                    cli: "loom browser take_screenshot --out shot.png"),
            browser(.browserConsole, "browser_console_messages",
                    "The console messages, uncaught errors and failed loads of the current page.",
                    ["level": enumeration(["error", "warning", "info", "debug"],
                                          "The lowest level shown, info by default (more severe ones included)."),
                     "all": boolean("Also the messages from before the last navigation.")],
                    cli: "loom browser console_messages"),
            browser(.browserNetwork, "browser_network_requests",
                    "The current page's main document and fetch/XHR requests, with their status.",
                    ["filter": string("Only the requests whose URL contains this.")],
                    cli: "loom browser network_requests"),
            browser(.browserEvaluate, "browser_evaluate",
                    "Run a JavaScript function in the page and answer its result as JSON. With a target, "
                    + "the element is its argument: (element) => element.textContent.",
                    ["function": string("() => { … } or (element) => { … }; may be async."),
                     "element": elementProperty, "target": targetProperty(optional: true), "ref": refAlias],
                    required: ["function"], cli: #"loom browser evaluate '() => document.title'"#),
            browser(.browserHandleDialog, "browser_handle_dialog",
                    "Answer the alert, confirm or prompt the page is waiting on (see ### Modal state); "
                    + "on a file chooser, cancel it.",
                    ["accept": boolean("OK (true) or Cancel (false)."),
                     "promptText": string("The text to answer a prompt with.")],
                    required: ["accept"], cli: #"loom browser handle_dialog '{"accept":true}'"#),
            browser(.browserTabs, "browser_tabs",
                    "List, open, select or close your browser's tabs.",
                    ["action": enumeration(["list", "new", "select", "close"], "What to do."),
                     "index": number("The tab, for select and close (close: the current one by default)."),
                     "url": string("The address a new tab opens.")],
                    required: ["action"], cli: "loom browser tabs list"),
            browser(.browserClose, "browser_close",
                    "Close every tab of your browser. Its profile (cookies, storage) is kept.",
                    [:], cli: "loom browser close"),
            browser(.browserFillForm, "browser_fill_form",
                    "Fill several fields of a form in one call, in order: text into textboxes, a state "
                    + "for checkboxes and radios, an option for comboboxes, a number for sliders. Answers "
                    + "the new snapshot; stops at the first field that fails, saying which.",
                    ["fields": array(.object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": string("The field's name, as you would say it."),
                            "type": enumeration(["textbox", "checkbox", "radio", "combobox", "slider"], "The kind of field."),
                            "target": targetProperty(optional: false),
                            "ref": refAlias,
                            "value": string("The text; true or false for a checkbox or radio; the option's "
                                            + "value or label for a combobox; a number for a slider."),
                        ]),
                        "required": .array([.string("name"), .string("type"), .string("value")]),
                    ]), "The fields to fill, 30 at most.")],
                    required: ["fields"],
                    cli: #"loom browser fill_form '{"fields":[{"name":"Email","type":"textbox","target":"e4","value":"a@b.c"}]}'"#),
            browser(.browserFileUpload, "browser_file_upload",
                    "Answer the file chooser the page opened (### Modal state) with files — click the "
                    + "file input first. Files from your working tree, or ones you copied into the folder "
                    + "a refusal names. No paths cancels the chooser.",
                    ["paths": array(.object(["type": .string("string")]), "Absolute paths of the files.")],
                    cli: "loom browser file_upload /path/to/photo.png"),
            browser(.browserResize, "browser_resize",
                    "Set the page's width in CSS pixels — 375 for a phone, 768 a tablet, 1280 a laptop — "
                    + "to test a responsive layout, for this session only (each project's default width is "
                    + "in Loom's Settings). The page is scaled into the panel; its height follows. 0 goes "
                    + "back to the panel's own width.",
                    ["width": number("The width in CSS pixels, 320 to 3840; 0 for the panel's."),
                     "height": number("Accepted for compatibility; the height follows the panel.")],
                    required: ["width"], cli: "loom browser resize 375"),
        ]
    }

    private static func browser(_ method: APIMethod, _ name: String, _ description: String,
                                _ properties: [String: JSONValue], required: [String] = [],
                                cli: String) -> APIToolSpec {
        var fields = properties
        fields["sessionId"] = string("Omit it: your own session. The browser answers its session's token only.")
        if method.answersSnapshot { fields["snapshot"] = snapshotProperty }
        return APIToolSpec(method: method, name: name, description: description,
                           inputSchema: object(fields, required: required), cliUsage: cli,
                           resultFormat: .content, preapprovable: true)
    }

    /// Every method's tool, whatever the engine: the Chromium catalog holds them all.
    public static func spec(for method: APIMethod) -> APIToolSpec {
        all(engine: .chromium).first { $0.method == method }!   // every method is listed: a missing one is a programming error
    }

    /// The tools a session's MCP server lists: without the browser's when
    /// they are turned off in Loom's Settings, worded for its engine.
    public static func tools(browser: Bool, engine: APIBrowserEngine = .webkit) -> [APIToolSpec] {
        browser ? all(engine: engine) : sessionTools
    }

    /// The MCP tool names Loom may pre-approve, as Claude Code's permission
    /// rules spell them (`mcp__<server>__<tool>`).
    public static func preapprovedRules(server: String = "loom", browser: Bool,
                                        engine: APIBrowserEngine = .webkit) -> [String] {
        tools(browser: browser, engine: engine).filter(\.preapprovable).map { "mcp__\(server)__\($0.name)" }
    }

    public static func spec(named name: String) -> APIToolSpec? {
        all(engine: .chromium).first { $0.name == name }
    }

    /// What an agent should know before its first call — the MCP `instructions`
    /// and the top of `loom docs`.
    public static let instructions = agentInstructions(browser: true)

    static let sessionInstructions = """
    You are running inside Loom, a macOS app that hosts coding-agent sessions. \
    Loom shows each session as a card with a title and badges. You may rename your \
    own session and set its badges so the person supervising sees where you are \
    (for instance `review` when you are ready for one). You cannot change your \
    session's state, start or stop sessions, or touch other sessions with your \
    own token. Prefer badges from the catalog over creating new ones.
    """

    static func browserInstructions(engine: APIBrowserEngine) -> String {
        browserInstructionsBody + " " + (engine == .chromium
            ? "Its events are real (trusted): CSS :hover applies, and pages keep running when "
                + "the panel is hidden."
            : "Events are synthetic: no CSS :hover, no native drag.")
    }

    static let browserInstructionsBody = """
    You also have your own browser, shown beside your terminal in Loom: use the \
    browser_* tools to test what you build — open your dev server \
    (`localhost:5173` is opened in http), act on the page, read its console and \
    requests. Work from browser_snapshot: it lists the page's elements with refs \
    (e12) that browser_click, browser_type and the others take; a ref is valid \
    only until the next snapshot. Each action answers the page's new snapshot; \
    when you chain actions on refs you already have, pass snapshot "none" for a \
    much shorter, faster answer. Screenshots are for looking, not for acting. \
    Its cookies and storage belong to this project's agent profile, never the \
    person's own browser.
    """

    public static func agentInstructions(browser: Bool, engine: APIBrowserEngine = .webkit) -> String {
        browser ? sessionInstructions + "\n\n" + browserInstructions(engine: engine) : sessionInstructions
    }

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
                    var kind = field["type"]?.stringValue ?? "any"
                    if case .array(let values)? = field["enum"] {
                        kind += " (" + values.compactMap(\.stringValue).joined(separator: " | ") + ")"
                    }
                    let text = field["description"]?.stringValue ?? ""
                    let mark = required.contains(key) ? " (required)" : ""
                    lines.append("  - `\(key)` — \(kind)\(mark). \(text)")
                }
            }
            lines.append("")
        }
        lines.append("Browser tools answer Markdown (### Page, ### Snapshot, ### Modal state…); "
                     + "the CLI prints it, and `--out <file>` saves a screenshot.")
        lines.append("")
        lines.append("Errors: `invalidRequest`, `unknownMethod`, `invalidParams`, `forbidden`, `notFound`, "
                     + "`conflict`, `timeout`, `unavailable`, `internalError`.")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Schema helpers

    private static let sessionIdProperty = string(
        "UUID of the session. Optional under a session token (yours); required under the global token.")

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func enumeration(_ values: [String], _ description: String) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string)),
                 "description": .string(description)])
    }

    private static func array(_ items: JSONValue, _ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": items, "description": .string(description)])
    }

    private static func targetProperty(optional: Bool) -> JSONValue {
        string("A ref from the latest browser_snapshot (e12), or a CSS selector matching one element."
               + (optional ? "" : " Required (or ref)."))
    }

    private static let refAlias = string("Same as target (Playwright's older name).")

    /// The opt-in that leaves the snapshot out of an action's answer.
    private static let snapshotProperty = enumeration(
        ["full", "none"],
        "What the answer shows of the page afterwards: full (default), its new snapshot; none, no snapshot — "
            + "a much shorter, faster answer (### Page, a dialog and events still show). The refs of your last "
            + "snapshot keep working while the page stays the same document.")

    private static let elementProperty = string(
        "A human-readable description of the element, echoed back (\"Submit button\").")

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
