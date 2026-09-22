// swift-tools-version: 5.10
import PackageDescription

// Boundaries set by the architecture (spec §6.1):
// services never depend on LoomUI; everyone may depend on LoomCore.
let package = Package(
    name: "Loom",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LoomApp", targets: ["LoomApp"]),
        .executable(name: "loom-hook", targets: ["loom-hook"]),
        // The CLI and the MCP server of the agents API (ADR-0010).
        .executable(name: "loom", targets: ["loom"]),
        .library(name: "LoomCore", targets: ["LoomCore"]),
    ],
    dependencies: [
        // Pinned to the minor: fast release cadence, and 1.20.0 is release-noted
        // as the last one before the announced breaking changes land
        // (docs/research/swiftterm-pty.md §1.6, recommandation 8).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.20.0")),
        // ADR-0002: GRDB for controlled migrations, FTS5, concurrent access.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Diff syntax colours: highlight.js under JavaScriptCore,
        // 190 languages. Pinned to the minor: the embedded JS changes on every minor.
        .package(url: "https://github.com/raspu/Highlightr.git", .upToNextMinor(from: "2.3.0")),
    ],
    targets: [
        .target(name: "LoomCore"),
        // The agents API contract (ADR-0010): envelopes, methods, models, socket client.
        // Depends on Core only — served by the app, consumed by the CLI and the MCP server.
        .target(name: "LoomAPI", dependencies: ["LoomCore"]),
        .target(name: "LoomTerminal", dependencies: ["LoomCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "LoomAgents", dependencies: ["LoomCore", "LoomAPI"]),
        .target(name: "LoomGit", dependencies: ["LoomCore"]),
        .target(name: "LoomWeb", dependencies: ["LoomCore", "LoomUI"]),
        .target(name: "LoomPersistence", dependencies: ["LoomCore", "LoomTerminal", "LoomAgents", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "LoomIPC", dependencies: ["LoomCore", "LoomAPI"]),
        // The helper the agents' hooks call (ADR-0005): stdin → socket, no dependencies.
        .executableTarget(name: "loom-hook"),
        // `loom`: the CLI and the MCP server, clients of the LoomAPI contract. The logic lives in
        // LoomCLI (testable); the executable is only an entry point.
        .target(name: "LoomCLI", dependencies: ["LoomAPI", "LoomCore"]),
        .executableTarget(name: "loom", dependencies: ["LoomCLI"]),
        .target(name: "LoomSessions", dependencies: ["LoomCore", "LoomTerminal", "LoomAgents", "LoomPersistence", "LoomGit"]),
        // Test adapters for the PTY seam, shared by the test targets (never shipped in the product).
        .target(name: "LoomTerminalTestSupport", dependencies: ["LoomCore", "LoomTerminal"]),
        // LoomUI reads LoomGit values (diff) to colour them: UI → service direction, never the reverse.
        .target(name: "LoomUI", dependencies: ["LoomCore", "LoomTerminal", "LoomGit",
                                               .product(name: "Highlightr", package: "Highlightr")]),
        .executableTarget(
            name: "LoomApp",
            dependencies: [
                "LoomCore", "LoomAPI", "LoomUI", "LoomTerminal", "LoomAgents",
                "LoomGit", "LoomWeb", "LoomPersistence", "LoomIPC",
                "LoomSessions",
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "LoomCoreTests", dependencies: ["LoomCore"]),
        .testTarget(name: "LoomAPITests", dependencies: ["LoomAPI", "LoomCore"]),
        .testTarget(name: "LoomCLITests", dependencies: ["LoomCLI", "LoomAPI", "LoomIPC", "LoomCore"]),
        .testTarget(name: "LoomAgentsTests", dependencies: ["LoomAgents"]),
        .testTarget(name: "LoomTerminalTests", dependencies: ["LoomTerminal", "LoomTerminalTestSupport", "LoomAgents"]),
        .testTarget(name: "LoomSessionsTests", dependencies: ["LoomSessions", "LoomTerminalTestSupport"]),
        .testTarget(name: "LoomIPCTests", dependencies: ["LoomIPC", "LoomAPI", "LoomCore"]),
        .testTarget(name: "LoomGitTests", dependencies: ["LoomGit", "LoomCore"]),
        .testTarget(name: "LoomPersistenceTests", dependencies: ["LoomPersistence"]),
        .testTarget(name: "LoomWebTests", dependencies: ["LoomWeb"]),
        .testTarget(name: "LoomUITests", dependencies: ["LoomUI", "LoomTerminal", "LoomGit"]),
    ]
)
