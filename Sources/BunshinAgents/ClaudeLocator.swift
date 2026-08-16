import Foundation

/// UIX-06 : localise le binaire `claude` pour l'onboarding et le canary check
/// (risque n°2 du cahier des charges). Pur : PATH et emplacements injectables.
public enum ClaudeLocator {

    /// Emplacements usuels hors PATH GUI (les apps ne voient pas le PATH du shell).
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
