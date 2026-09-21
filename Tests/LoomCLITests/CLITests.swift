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
