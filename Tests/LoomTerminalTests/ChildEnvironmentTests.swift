import Testing
@testable import LoomTerminal
import Foundation

// Seam: the environment a session's process is born with. The overlay wins,
// the PATH is never empty, and a prefix leads it without replacing it.

@Suite("SessionRuntime — child environment")
struct ChildEnvironmentTests {

    @Test("a PATH prefix leads the inherited PATH, once, and never replaces it")
    func prefixeDePath() {
        let base = ["PATH": "/usr/local/bin:/usr/bin", "HOME": "/Users/x"]
        let environment = SessionRuntime.childEnvironment(
            overlay: ["LOOM_SESSION_TOKEN": "t"],
            pathPrefix: ["/Applications/Loom.app/Contents/MacOS", "/usr/bin", ""],
            base: base)
        #expect(environment["PATH"] == "/Applications/Loom.app/Contents/MacOS:/usr/local/bin:/usr/bin",
                "the new directory leads; one already present is not doubled; a blank is dropped")
        #expect(environment["LOOM_SESSION_TOKEN"] == "t", "the overlay lands")
        #expect(environment["HOME"] == "/Users/x", "the base survives")
        #expect(environment["TERM"] == "xterm-256color")
    }

    @Test("an overlay PATH still wins, and the prefix leads it")
    func overlayPuisPrefixe() {
        let environment = SessionRuntime.childEnvironment(
            overlay: ["PATH": "/opt/bin"], pathPrefix: ["/loom"], base: ["PATH": "/usr/bin"])
        #expect(environment["PATH"] == "/loom:/opt/bin")
    }

    @Test("no PATH anywhere: the system fallback, then the prefix")
    func sansPath() {
        let environment = SessionRuntime.childEnvironment(overlay: [:], pathPrefix: ["/loom"], base: [:])
        #expect(environment["PATH"] == "/loom:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
