import Testing
import Foundation
import LoomCore
@testable import LoomGit

// The Browse table's rows: one id per PR per project, sort keys that put
// what needs attention first, and the same instant filter as the rest.
@Suite("PRBrowseRow — ids, sort keys, filter")
struct PRBrowseRowTests {

    private let project = ProjectID()
    private let other = ProjectID()

    private func pr(_ number: Int, decision: String = "", passing: Bool = true,
                    checks: [GitHubService.Check] = [], additions: Int = 0,
                    deletions: Int = 0, branch: String = "feature") -> GitHubService.PullRequest {
        GitHubService.PullRequest(number: number, title: "Title \(number)", author: "ana",
                                  branch: branch, baseBranch: "main", reviewDecision: decision,
                                  checksPassing: passing, isDraft: false, updatedAt: "", url: "",
                                  reviewers: ["bob"], additions: additions, deletions: deletions,
                                  checks: checks)
    }

    private func hit(_ number: Int, repo: String = "acme/api") -> GitHubService.PRSearchHit {
        GitHubService.PRSearchHit(repo: repo, number: number, title: "Hit \(number)", author: "cy")
    }

    @Test("a project row is keyed like its PR tab; two projects, two ids")
    func projectRowIDs() {
        let a = PRBrowseRow(pr: pr(7), projectID: project, projectName: "api", repo: "acme/api")
        let b = PRBrowseRow(pr: pr(7), projectID: other, projectName: "api-2", repo: "acme/api")
        #expect(a.id == PRTab.key(project, 7))
        #expect(a.id != b.id)
        #expect(a.place == "acme/api")
    }

    @Test("a project with no known repository shows its name")
    func placeFallsBackToProjectName() {
        let row = PRBrowseRow(pr: pr(1), projectID: project, projectName: "local", repo: nil)
        #expect(row.place == "local")
        #expect(row.repo.isEmpty)
    }

    @Test("a hit is keyed by its repository until a project clones it")
    func hitIDs() {
        #expect(PRBrowseRow(hit: hit(3)).id == "acme/api#3")
        #expect(PRBrowseRow(hit: hit(3), projectID: project).id == PRTab.key(project, 3))
    }

    @Test("CI sorts failing, then running, then green; a hit last")
    func ciRank() {
        let failing = PRBrowseRow(pr: pr(1, passing: false), projectID: project, projectName: "p", repo: nil)
        let running = PRBrowseRow(pr: pr(2, checks: [.init(name: "ci", state: .pending)]),
                                  projectID: project, projectName: "p", repo: nil)
        let green = PRBrowseRow(pr: pr(3), projectID: project, projectName: "p", repo: nil)
        let unknown = PRBrowseRow(hit: hit(4))
        #expect([failing, running, green, unknown].map(\.ciRank) == [0, 1, 2, 3])
    }

    @Test("review sorts changes requested first, approved last of the known")
    func reviewRank() {
        let ranks = ["CHANGES_REQUESTED", "REVIEW_REQUIRED", "", "APPROVED"].enumerated().map {
            PRBrowseRow(pr: pr($0.offset, decision: $0.element), projectID: project,
                        projectName: "p", repo: nil).reviewRank
        }
        #expect(ranks == [0, 1, 2, 3])
        #expect(PRBrowseRow(hit: hit(9)).reviewRank == 4)
    }

    @Test("size is the lines touched; unknown below an empty PR")
    func size() {
        let row = PRBrowseRow(pr: pr(1, additions: 10, deletions: 4), projectID: project,
                              projectName: "p", repo: nil)
        #expect(row.size == 14)
        #expect(PRBrowseRow(hit: hit(2)).size < 0)
    }

    @Test("the filter reaches the repository, the branch and the reviewers")
    func filter() {
        let row = PRBrowseRow(pr: pr(12, branch: "fix/login"), projectID: project,
                              projectName: "p", repo: "acme/web")
        #expect(row.matches(query: ""))
        #expect(row.matches(query: "acme/web #12"))
        #expect(row.matches(query: "login bob"))
        #expect(!row.matches(query: "login carol"))
        #expect(PRBrowseRow(hit: hit(5)).matches(query: "acme cy"))
    }
}
