import Foundation

/// UIX-06: locates the `claude` binary for onboarding and the canary check
/// (risk #2 in the spec). Pure: PATH and locations are injectable.
public enum ClaudeLocator {

    /// Usual locations outside the GUI PATH (apps do not see the shell's PATH).
    public static let wellKnownLocations: [String] = [
        NSHomeDirectory() + "/.claude/local/claude",
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    public static func locate(searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                              extraLocations: [String] = wellKnownLocations) -> URL? {
        let candidates = searchPath.split(separator: ":").map { "\($0)/claude" } + extraLocations
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
