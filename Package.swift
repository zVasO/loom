// swift-tools-version: 5.10
import PackageDescription

// Frontières imposées par l'architecture (§6.1 du cahier des charges) :
// les services ne dépendent jamais de BunshinUI ; tout le monde peut dépendre de BunshinCore.
let package = Package(
    name: "Bunshin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BunshinApp", targets: ["BunshinApp"]),
        .executable(name: "bunshin-hook", targets: ["bunshin-hook"]),
        .library(name: "BunshinCore", targets: ["BunshinCore"]),
    ],
    dependencies: [
        // Épinglé en minor : cadence de release rapide et refonte I/O annoncée
        // (docs/research/swiftterm-pty.md §1.6, recommandation 8).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.18.0")),
        // ADR-0002 : GRDB pour migrations contrôlées, FTS5, accès concurrents.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "BunshinCore"),
        .target(name: "BunshinTerminal", dependencies: ["BunshinCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "BunshinAgents", dependencies: ["BunshinCore"]),
        .target(name: "BunshinGit", dependencies: ["BunshinCore"]),
        .target(name: "BunshinWeb", dependencies: ["BunshinCore"]),
        .target(name: "BunshinPersistence", dependencies: ["BunshinCore", "BunshinTerminal", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "BunshinIPC", dependencies: ["BunshinCore"]),
        // Le helper appelé par les hooks des agents (ADR-0005) : stdin → socket, sans dépendance.
        .executableTarget(name: "bunshin-hook"),
        .target(name: "BunshinSessions", dependencies: ["BunshinCore", "BunshinTerminal", "BunshinAgents", "BunshinPersistence"]),
        // Adapters de test du seam PTY, partagés par les cibles de test (jamais exposé en produit).
        .target(name: "BunshinTerminalTestSupport", dependencies: ["BunshinCore", "BunshinTerminal"]),
        .target(name: "BunshinUI", dependencies: ["BunshinCore", "BunshinTerminal"]),
        .executableTarget(
            name: "BunshinApp",
            dependencies: [
                "BunshinCore", "BunshinUI", "BunshinTerminal", "BunshinAgents",
                "BunshinGit", "BunshinWeb", "BunshinPersistence", "BunshinIPC",
                "BunshinSessions",
            ]
        ),
        .testTarget(name: "BunshinCoreTests", dependencies: ["BunshinCore"]),
        .testTarget(name: "BunshinAgentsTests", dependencies: ["BunshinAgents"]),
        .testTarget(name: "BunshinTerminalTests", dependencies: ["BunshinTerminal", "BunshinTerminalTestSupport"]),
        .testTarget(name: "BunshinSessionsTests", dependencies: ["BunshinSessions", "BunshinTerminalTestSupport"]),
        .testTarget(name: "BunshinIPCTests", dependencies: ["BunshinIPC"]),
        .testTarget(name: "BunshinGitTests", dependencies: ["BunshinGit"]),
        .testTarget(name: "BunshinPersistenceTests", dependencies: ["BunshinPersistence"]),
    ]
)
