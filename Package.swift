// swift-tools-version: 5.10
import PackageDescription

// Frontières imposées par l'architecture (§6.1 du cahier des charges) :
// les services ne dépendent jamais de LoomUI ; tout le monde peut dépendre de LoomCore.
let package = Package(
    name: "Loom",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LoomApp", targets: ["LoomApp"]),
        .executable(name: "loom-hook", targets: ["loom-hook"]),
        .library(name: "LoomCore", targets: ["LoomCore"]),
    ],
    dependencies: [
        // Épinglé en minor : cadence de release rapide et refonte I/O annoncée
        // (docs/research/swiftterm-pty.md §1.6, recommandation 8).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.18.0")),
        // ADR-0002 : GRDB pour migrations contrôlées, FTS5, accès concurrents.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "LoomCore"),
        .target(name: "LoomTerminal", dependencies: ["LoomCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "LoomAgents", dependencies: ["LoomCore"]),
        .target(name: "LoomGit", dependencies: ["LoomCore"]),
        .target(name: "LoomWeb", dependencies: ["LoomCore", "LoomUI"]),
        .target(name: "LoomPersistence", dependencies: ["LoomCore", "LoomTerminal", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "LoomIPC", dependencies: ["LoomCore"]),
        // Le helper appelé par les hooks des agents (ADR-0005) : stdin → socket, sans dépendance.
        .executableTarget(name: "loom-hook"),
        .target(name: "LoomSessions", dependencies: ["LoomCore", "LoomTerminal", "LoomAgents", "LoomPersistence", "LoomGit"]),
        // Adapters de test du seam PTY, partagés par les cibles de test (jamais exposé en produit).
        .target(name: "LoomTerminalTestSupport", dependencies: ["LoomCore", "LoomTerminal"]),
        .target(name: "LoomUI", dependencies: ["LoomCore", "LoomTerminal"]),
        .executableTarget(
            name: "LoomApp",
            dependencies: [
                "LoomCore", "LoomUI", "LoomTerminal", "LoomAgents",
                "LoomGit", "LoomWeb", "LoomPersistence", "LoomIPC",
                "LoomSessions",
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "LoomCoreTests", dependencies: ["LoomCore"]),
        .testTarget(name: "LoomAgentsTests", dependencies: ["LoomAgents"]),
        .testTarget(name: "LoomTerminalTests", dependencies: ["LoomTerminal", "LoomTerminalTestSupport"]),
        .testTarget(name: "LoomSessionsTests", dependencies: ["LoomSessions", "LoomTerminalTestSupport"]),
        .testTarget(name: "LoomIPCTests", dependencies: ["LoomIPC"]),
        .testTarget(name: "LoomGitTests", dependencies: ["LoomGit"]),
        .testTarget(name: "LoomPersistenceTests", dependencies: ["LoomPersistence"]),
        .testTarget(name: "LoomWebTests", dependencies: ["LoomWeb"]),
        .testTarget(name: "LoomUITests", dependencies: ["LoomUI"]),
    ]
)
