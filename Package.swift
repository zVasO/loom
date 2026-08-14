// swift-tools-version: 5.10
import PackageDescription

// Frontières imposées par l'architecture (§6.1 du cahier des charges) :
// les services ne dépendent jamais de BunshinUI ; tout le monde peut dépendre de BunshinCore.
let package = Package(
    name: "Bunshin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BunshinApp", targets: ["BunshinApp"]),
        .library(name: "BunshinCore", targets: ["BunshinCore"]),
    ],
    dependencies: [
        // Épinglé en minor : cadence de release rapide et refonte I/O annoncée
        // (docs/research/swiftterm-pty.md §1.6, recommandation 8).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.18.0")),
    ],
    targets: [
        .target(name: "BunshinCore"),
        .target(name: "BunshinTerminal", dependencies: ["BunshinCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "BunshinAgents", dependencies: ["BunshinCore"]),
        .target(name: "BunshinGit", dependencies: ["BunshinCore"]),
        .target(name: "BunshinWeb", dependencies: ["BunshinCore"]),
        .target(name: "BunshinPersistence", dependencies: ["BunshinCore"]),
        .target(name: "BunshinIPC", dependencies: ["BunshinCore"]),
        .target(name: "BunshinUI", dependencies: ["BunshinCore"]),
        .executableTarget(
            name: "BunshinApp",
            dependencies: [
                "BunshinCore", "BunshinUI", "BunshinTerminal", "BunshinAgents",
                "BunshinGit", "BunshinWeb", "BunshinPersistence", "BunshinIPC",
            ]
        ),
        .testTarget(name: "BunshinCoreTests", dependencies: ["BunshinCore"]),
        .testTarget(name: "BunshinAgentsTests", dependencies: ["BunshinAgents"]),
        .testTarget(name: "BunshinTerminalTests", dependencies: ["BunshinTerminal"]),
    ]
)
