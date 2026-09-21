import Testing
@testable import LoomGit

// The link between a local project and the repository GitHub knows: the
// remote's URL, in every spelling git accepts, read back as `owner/name`.
@Suite("GitHubRepoName — owner/name from a remote")
struct GitHubRepoNameTests {

    @Test("every git spelling of a github.com remote reads as owner/name")
    func remoteSpellings() {
        for remote in ["git@github.com:acme/core.git", "git@github.com:acme/core",
                       "https://github.com/acme/core.git", "https://github.com/acme/core",
                       "https://github.com/acme/core/", "ssh://git@github.com/acme/core.git",
                       "git://github.com/acme/core.git", "github.com/acme/core",
                       "  https://github.com/acme/core.git\n"] {
            #expect(GitHubRepoName.parse(remoteURL: remote) == "acme/core", remote)
        }
    }

    @Test("an SSH host alias for a second account still points at github.com")
    func hostAlias() {
        #expect(GitHubRepoName.parse(remoteURL: "git@github.com-work:acme/core.git") == "acme/core")
    }

    @Test("another host is not a GitHub repository")
    func otherHosts() {
        for remote in ["git@gitlab.com:acme/core.git", "https://github.acme.com/acme/core",
                       "https://notgithub.com/acme/core", "https://github.com.evil/acme/core",
                       "", "https://github.com/acme", "https://github.com/acme/core/extra"] {
            #expect(GitHubRepoName.parse(remoteURL: remote) == nil, remote)
        }
    }

    @Test("a typed owner/name is accepted trimmed, anything else refused")
    func typedName() {
        #expect(GitHubRepoName.parse(nameWithOwner: " acme/core ") == "acme/core")
        #expect(GitHubRepoName.parse(nameWithOwner: "acme") == nil)
        #expect(GitHubRepoName.parse(nameWithOwner: "acme/core/x") == nil)
        #expect(GitHubRepoName.parse(nameWithOwner: "acme/co re") == nil)
        #expect(GitHubRepoName.parse(nameWithOwner: "/core") == nil)
    }

    @Test("the halves come apart")
    func halves() {
        #expect(GitHubRepoName.name(of: "acme/core") == "core")
        #expect(GitHubRepoName.owner(of: "acme/core") == "acme")
    }
}

// A PR named from outside the list: pasted URL, owner/repo#n, a bare number.
@Suite("PRReference — a pull request named by hand")
struct PRReferenceTests {

    @Test("a github.com PR URL, with or without a tail, names repo and number")
    func urls() {
        for text in ["https://github.com/acme/core/pull/42",
                     "https://github.com/acme/core/pull/42/files",
                     "https://github.com/acme/core/pull/42#discussion_r1",
                     "https://github.com/acme/core/pull/42?diff=split",
                     "github.com/acme/core/pull/42/"] {
            #expect(PRReference.parse(text) == PRReference(repo: "acme/core", number: 42), text)
        }
    }

    @Test("owner/repo#n and a bare number")
    func shorthand() {
        #expect(PRReference.parse("acme/core#7") == PRReference(repo: "acme/core", number: 7))
        #expect(PRReference.parse("#7") == PRReference(repo: nil, number: 7))
        #expect(PRReference.parse("7") == PRReference(repo: nil, number: 7))
    }

    @Test("a repository URL, an issue URL, a word or a sentence are not a PR")
    func notAReference() {
        for text in ["https://github.com/acme/core", "https://github.com/acme/core/issues/3",
                     "https://github.com/acme/core/pull/", "https://github.com/acme/core/pull/x",
                     "cache", "fix the cache", "acme/core", "0", "#0", ""] {
            #expect(PRReference.parse(text) == nil, text)
        }
    }
}
