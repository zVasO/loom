import Testing
import LoomAPI
import LoomCLI
import LoomCore
import Foundation

// Seam: the words the CLI accepts and what it makes of them — no socket here.

@Suite("loom — command parsing")
struct CLIParseTests {

    @Test("verbs map to commands, flags anywhere")
    func verbes() throws {
        #expect(try CLI.parse(["version"]).0 == .version)
        #expect(try CLI.parse(["session", "get"]).0 == .sessionGet)
        #expect(try CLI.parse(["session", "title", "Fix", "the", "cache"]).0 == .sessionTitle("Fix the cache"))
        #expect(try CLI.parse(["badge", "list"]).0 == .badgeList)
        #expect(try CLI.parse(["badge", "set", "review", "urgent"]).0 == .badgeSet(["review", "urgent"]))
        #expect(try CLI.parse(["badge", "add", "wip"]).0 == .badgeAdd("wip"))
        #expect(try CLI.parse(["badge", "remove", "wip"]).0 == .badgeRemove("wip"))
        #expect(try CLI.parse(["badge", "clear"]).0 == .badgeClear)
        #expect(try CLI.parse(["docs"]).0 == .docs)
        #expect(try CLI.parse(["mcp"]).0 == .mcp)
        #expect(try CLI.parse([]).0 == .help)
        #expect(try CLI.parse(["--help"]).0 == .help)

        let (create, options) = try CLI.parse(["--global", "badge", "create", "perf", "--color", "#112233",
                                               "--session", "abc", "--socket", "/s", "--token", "t"])
        #expect(create == .badgeCreate(name: "perf", colorHex: "#112233"))
        #expect(options.global && options.sessionId == "abc" && options.socket == "/s" && options.token == "t")

        let (sessions, archived) = try CLI.parse(["sessions", "--archived"])
        #expect(sessions == .sessions(includeArchived: true))
        #expect(archived.archived)
    }

    @Test("browser verbs: the tool by its short name, JSON or its one obvious value")
    func verbesNavigateur() throws {
        #expect(try CLI.parse(["browser", "navigate", "localhost:5173"]).0
                == .browser(.browserNavigate, .object(["url": .string("localhost:5173")])))
        #expect(try CLI.parse(["browser", "browser_click", "e12"]).0
                == .browser(.browserClick, .object(["target": .string("e12")])))
        #expect(try CLI.parse(["browser", "type", #"{"target":"e5","text":"milk","submit":true}"#]).0
                == .browser(.browserType, .object(["target": .string("e5"), "text": .string("milk"),
                                                   "submit": .bool(true)])))
        #expect(try CLI.parse(["browser", "press_key", "Shift+Tab"]).0
                == .browser(.browserPressKey, .object(["key": .string("Shift+Tab")])))
        #expect(try CLI.parse(["browser", "evaluate", "()", "=>", "document.title"]).0
                == .browser(.browserEvaluate, .object(["function": .string("() => document.title")])))
        #expect(try CLI.parse(["browser", "handle_dialog", "accept"]).0
                == .browser(.browserHandleDialog, .object(["accept": .bool(true)])))
        let (shot, options) = try CLI.parse(["browser", "take_screenshot", "--out", "s.png"])
        #expect(shot == .browser(.browserScreenshot, .object([:])))
        #expect(options.out == "s.png")
        #expect(try CLI.parse(["browser", "tabs", "list"]).0
                == .browser(.browserTabs, .object(["action": .string("list")])))
        #expect(try CLI.parse(["browser", "tabs", "select", "1"]).0
                == .browser(.browserTabs, .object(["action": .string("select"), "index": .number(1)])))
        #expect(try CLI.parse(["browser", "tabs", "new", "localhost:8080"]).0
                == .browser(.browserTabs, .object(["action": .string("new"), "url": .string("localhost:8080")])))
        #expect(try CLI.parse(["browser", "wait_for", "3"]).0
                == .browser(.browserWaitFor, .object(["time": .number(3)])), "a number is seconds")
        #expect(try CLI.parse(["browser", "wait_for", "Saved"]).0
                == .browser(.browserWaitFor, .object(["text": .string("Saved")])))
        #expect(try CLI.parse(["browser", "file_upload", "/tmp/a.png", "/tmp/b.png"]).0
                == .browser(.browserFileUpload, .object(["paths": .array([.string("/tmp/a.png"), .string("/tmp/b.png")])])))
        #expect(try CLI.parse(["browser", "resize", "1280x800"]).0
                == .browser(.browserResize, .object(["width": .number(1280)])))
        #expect(throws: CLI.ParseError.self) { try CLI.parse(["browser", "resize", "wide"]) }
    }

    @Test("run_code: the code as it is, a script file with @, or JSON")
    func executerDuCode() throws {
        #expect(try CLI.parse(["browser", "run_code", "async (page) => { return await page.title(); }"]).0
                == .browser(.browserRunCode, .object(["code": .string("async (page) => { return await page.title(); }")])))
        #expect(try CLI.parse(["browser", "run_code", #"{"code":"async (page) => 1","snapshot":"none"}"#]).0
                == .browser(.browserRunCode, .object(["code": .string("async (page) => 1"), "snapshot": .string("none")])))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loom-run-\(UUID().uuidString.prefix(6)).js")
        let script = "async (page) => {\n  await page.getByRole('button', { name: 'Save' }).click();\n  return page.url();\n}\n"
        try Data(script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try CLI.parse(["browser", "run_code", "@" + file.path]).0
                == .browser(.browserRunCode, .object(["code": .string(script)])), "read whole, newlines kept")
        #expect(throws: CLI.ParseError.self, "a missing file") {
            try CLI.parse(["browser", "run_code", "@/nonexistent/loom-script.js"])
        }
        let large = FileManager.default.temporaryDirectory.appendingPathComponent("loom-run-large-\(UUID().uuidString.prefix(6)).js")
        try Data(repeating: 0x20, count: 70_000).write(to: large)
        defer { try? FileManager.default.removeItem(at: large) }
        #expect(throws: CLI.ParseError.self, "over 64 KB") { try CLI.parse(["browser", "run_code", "@" + large.path]) }
    }

    @Test("browser usage errors are said plainly")
    func erreursNavigateur() {
        #expect(throws: CLI.ParseError.missingArgument("browser tool (see loom docs)")) { try CLI.parse(["browser"]) }
        #expect(throws: CLI.ParseError.unknownCommand("browser fly")) { try CLI.parse(["browser", "fly"]) }
        #expect(throws: CLI.ParseError.missingValue("--out")) { try CLI.parse(["browser", "snapshot", "--out"]) }
        #expect(throws: CLI.ParseError.self) { try CLI.parse(["browser", "type", "hello"]) }
        #expect(throws: CLI.ParseError.self) { try CLI.parse(["browser", "navigate", "{not json"]) }
        #expect(throws: CLI.ParseError.self) { try CLI.parse(["browser", "tabs", "select", "first"]) }
        #expect(throws: CLI.ParseError.self, "--out is the screenshot's") {
            try CLI.parse(["browser", "snapshot", "--out", "s.png"])
        }
        #expect(throws: CLI.ParseError.self) { try CLI.parse(["sessions", "--out", "s.png"]) }
    }

    @Test("a missing argument or an unknown verb is a usage error, said plainly")
    func erreursDUsage() {
        #expect(throws: CLI.ParseError.missingArgument("title")) { try CLI.parse(["session", "title"]) }
        #expect(throws: CLI.ParseError.missingArgument("badge name")) { try CLI.parse(["badge", "add"]) }
        #expect(throws: CLI.ParseError.missingValue("--color")) { try CLI.parse(["badge", "create", "x", "--color"]) }
        #expect(throws: CLI.ParseError.unknownCommand("badge fly")) { try CLI.parse(["badge", "fly"]) }
    }

    @Test("help and docs need no socket and exit 0")
    func aideEtDocsSansSocket() {
        var printed = ""
        let code = CLI.run(["docs"], environment: [:], output: { printed += $0 }, error: { _ in })
        #expect(code == 0)
        #expect(printed.hasPrefix("# Loom agents API"))
        var help = ""
        #expect(CLI.run(["--help"], environment: [:], output: { help += $0 }, error: { _ in }) == 0)
        #expect(help.contains("loom badge add <name>"))
        #expect(help.contains("loom browser <tool>"))
    }

    @Test("without a socket or a token, the run says what is missing and exits 2")
    func sansConnexion() {
        var said = ""
        let code = CLI.run(["version"], environment: ["HOME": "/nonexistent-home"],
                           output: { _ in }, error: { said += $0 })
        #expect(code == 2)
        #expect(said.contains("no socket"))
    }
}

@Suite("loom — connection resolution")
struct ConnectionTests {

    @Test("flags win over the environment; the environment over the support directory")
    func priorites() throws {
        let env = ["LOOM_SOCKET": "/env.sock", "LOOM_SESSION_TOKEN": "env-token"]
        let flagged = try Connection.resolve(socket: "/flag.sock", token: "flag-token", global: false,
                                             environment: env)
        #expect(flagged == Connection(socketPath: "/flag.sock", token: "flag-token"))
        let fromEnv = try Connection.resolve(socket: nil, token: nil, global: false, environment: env)
        #expect(fromEnv == Connection(socketPath: "/env.sock", token: "env-token"))
    }

    @Test("--global reads api-token beside Loom's database")
    func tokenGlobal() throws {
        let env = ["LOOM_SOCKET": "/env.sock", "LOOM_SUPPORT_DIR": "/support"]
        let connection = try Connection.resolve(socket: nil, token: nil, global: true, environment: env,
                                                readFile: { url in
                                                    url.path == "/support/api-token" ? "  global-secret\n" : nil
                                                })
        #expect(connection.token == "global-secret", "trimmed, from the support directory")
        #expect(throws: Connection.ResolutionError.globalTokenUnreadable("/support/api-token")) {
            try Connection.resolve(socket: nil, token: nil, global: true, environment: env, readFile: { _ in nil })
        }
    }

    @Test("no token is an error that names the ways to get one")
    func sansToken() {
        #expect(throws: Connection.ResolutionError.noToken) {
            try Connection.resolve(socket: "/s", token: nil, global: false, environment: [:])
        }
        #expect(Connection.ResolutionError.noToken.description.contains("--global"))
    }
}
