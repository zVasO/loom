import Foundation

/// A repository as GitHub names it: `owner/name`. Pure parsing of what a
/// clone carries in its remote — the one link between a local project and
/// the repository the PRs tab lists.
public enum GitHubRepoName {
    /// `git@github.com:o/r.git`, `https://github.com/o/r`, `ssh://git@github.com/o/r.git`
    /// → `o/r`. Another host (GHE, GitLab…) is not a GitHub repository: nil.
    public static func parse(remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = trimmed.range(of: "github.com") else { return nil }
        // The host is exactly github.com: what precedes it is a scheme, a
        // user (`git@`) or nothing — never another label (`notgithub.com`).
        if let last = trimmed[..<host.lowerBound].last, last != "/" && last != "@" { return nil }
        var after = trimmed[host.upperBound...]
        // An SSH host alias (`github.com-work:o/r`, one per account in
        // ~/.ssh/config) still points at github.com.
        if after.hasPrefix("-"), let colon = after.firstIndex(of: ":") { after = after[colon...] }
        guard let separator = after.first, separator == ":" || separator == "/" else { return nil }
        var path = after.dropFirst()
        while path.hasPrefix("/") { path = path.dropFirst() }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isSegment(parts[0]), isSegment(parts[1]) else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// `owner/name` typed by hand: two segments, GitHub's own characters.
    public static func parse(nameWithOwner: String) -> String? {
        let trimmed = nameWithOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isSegment(parts[0]), isSegment(parts[1]) else { return nil }
        return trimmed
    }

    /// The `name` half — what a clone is named on disk.
    public static func name(of nameWithOwner: String) -> String {
        nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner
    }

    public static func owner(of nameWithOwner: String) -> String {
        nameWithOwner.split(separator: "/").first.map(String.init) ?? nameWithOwner
    }

    private static func isSegment(_ segment: Substring) -> Bool {
        !segment.isEmpty && segment.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }
}

/// A pull request named from outside the list: pasted URL, `owner/repo#12`,
/// or a bare number that means "in the current project".
public struct PRReference: Equatable, Sendable {
    /// `owner/name`, or nil when the text named only a number.
    public let repo: String?
    public let number: Int

    public init(repo: String?, number: Int) {
        self.repo = repo
        self.number = number
    }

    /// `https://github.com/o/r/pull/12`, `…/pull/12/files#diff-…`, `o/r#12`,
    /// `#12`, `12`. Anything else — a repository URL, a word — is nil.
    public static func parse(_ text: String) -> PRReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if let range = trimmed.range(of: "github.com/") {
            let parts = trimmed[range.upperBound...].split(separator: "/")
            guard parts.count >= 4, parts[2] == "pull",
                  let number = leadingNumber(parts[3]),
                  let repo = GitHubRepoName.parse(nameWithOwner: "\(parts[0])/\(parts[1])")
            else { return nil }
            return PRReference(repo: repo, number: number)
        }
        if let hash = trimmed.firstIndex(of: "#") {
            let before = String(trimmed[..<hash])
            guard let number = leadingNumber(trimmed[trimmed.index(after: hash)...]) else { return nil }
            if before.isEmpty { return PRReference(repo: nil, number: number) }
            guard let repo = GitHubRepoName.parse(nameWithOwner: before) else { return nil }
            return PRReference(repo: repo, number: number)
        }
        if let number = Int(trimmed), number > 0 { return PRReference(repo: nil, number: number) }
        return nil
    }

    /// The digits at the start of a path segment: `12`, `12?x`, `12#hash`.
    private static func leadingNumber(_ segment: Substring) -> Int? {
        let digits = segment.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits), number > 0 else { return nil }
        return number
    }
}
