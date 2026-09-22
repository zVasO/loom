import Testing
import Foundation
import LoomCore
@testable import LoomGit

// One tab per open pull request: a click previews, a review pins, and
// what was open comes back after a relaunch.
@Suite("PRTabs — preview, pin, close, and what survives")
struct PRTabsTests {

    private let project = ProjectID()
    private let other = ProjectID()

    private func pr(_ number: Int, title: String = "t") -> GitHubService.PullRequest {
        GitHubService.PullRequest(number: number, title: title, author: "a", branch: "b",
                                  baseBranch: "main", reviewDecision: "", checksPassing: true,
                                  isDraft: false, updatedAt: "", url: "", headSHA: "h\(number)")
    }

    @Test("a click previews; the next click reuses the preview in place")
    func previewIsReused() {
        var tabs = PRTabs()
        tabs.show(pr(1), in: project)
        #expect(tabs.tabs.map(\.pr.number) == [1])
        #expect(tabs.active?.isPreview == true)
        tabs.show(pr(2), in: project)
        #expect(tabs.tabs.map(\.pr.number) == [2], "the preview was replaced, not stacked")
        #expect(tabs.activeID == PRTab.key(project, 2))
    }

    @Test("a pinned tab is never replaced; a new preview opens beside it")
    func pinnedStays() {
        var tabs = PRTabs()
        tabs.open(pr(1), in: project)
        #expect(tabs.active?.isPreview == false)
        tabs.show(pr(2), in: project)
        #expect(tabs.tabs.map(\.pr.number) == [1, 2])
        tabs.show(pr(3), in: project)
        #expect(tabs.tabs.map(\.pr.number) == [1, 3], "the preview slot is the second tab")
        #expect(tabs.tabs[1].isPreview)
    }

    @Test("showing an open PR activates its tab — never a second one")
    func noDuplicate() {
        var tabs = PRTabs()
        tabs.open(pr(1), in: project)
        tabs.open(pr(2), in: project)
        tabs.show(pr(1, title: "renamed"), in: project)
        #expect(tabs.tabs.count == 2)
        #expect(tabs.activeID == PRTab.key(project, 1))
        #expect(tabs.active?.pr.title == "renamed")
        #expect(tabs.active?.isPreview == false, "showing an open pinned tab keeps it pinned")
    }

    @Test("the same number in two projects is two tabs")
    func keyIncludesProject() {
        var tabs = PRTabs()
        tabs.open(pr(7), in: project)
        tabs.open(pr(7), in: other)
        #expect(tabs.tabs.count == 2)
    }

    @Test("closing the active tab lands on the right neighbour, else the left")
    func closeNeighbour() {
        var tabs = PRTabs()
        for number in 1...3 { tabs.open(pr(number), in: project) }
        tabs.activate(PRTab.key(project, 2))
        tabs.close(PRTab.key(project, 2))
        #expect(tabs.activeID == PRTab.key(project, 3))
        tabs.close(PRTab.key(project, 3))
        #expect(tabs.activeID == PRTab.key(project, 1))
        tabs.close(PRTab.key(project, 1))
        #expect(tabs.activeID == nil && tabs.isEmpty)
    }

    @Test("closing an inactive tab keeps the active one; close others keeps one")
    func closeInactive() {
        var tabs = PRTabs()
        for number in 1...3 { tabs.open(pr(number), in: project) }
        tabs.close(PRTab.key(project, 1))
        #expect(tabs.activeID == PRTab.key(project, 3))
        tabs.closeOthers(PRTab.key(project, 2))
        #expect(tabs.tabs.map(\.pr.number) == [2])
        #expect(tabs.activeID == PRTab.key(project, 2))
    }

    @Test("next and previous wrap around")
    func stepping() {
        var tabs = PRTabs()
        for number in 1...3 { tabs.open(pr(number), in: project) }
        tabs.activateNext()
        #expect(tabs.activeID == PRTab.key(project, 1), "from the last, next wraps to the first")
        tabs.activatePrevious()
        #expect(tabs.activeID == PRTab.key(project, 3))
        tabs.activate("nope")
        #expect(tabs.activeID == PRTab.key(project, 3), "an unknown id is ignored")
    }

    @Test("a refetched list updates the row and nothing the user set")
    func refreshKeepsUserState() throws {
        var tabs = PRTabs()
        tabs.open(pr(1), in: project)
        tabs.show(pr(2), in: project)
        let key = PRTab.key(project, 1)
        tabs.setDrawer(open: true, for: key)
        tabs.setSummary("LGTM", for: key)
        tabs.refresh(from: [pr(1, title: "new title")], in: project)
        let tab = try #require(tabs.tab(key))
        #expect(tab.pr.title == "new title")
        #expect(tab.drawerOpen && tab.reviewSummary == "LGTM" && !tab.isPreview)
        #expect(tabs.tab(PRTab.key(project, 2))?.isPreview == true)
        tabs.refresh(from: [pr(1, title: "other project")], in: other)
        #expect(tabs.tab(key)?.pr.title == "new title", "another project's list is not this tab's")
    }

    @Test("tabs of a removed project are dropped, the active one first of the rest")
    func keepProjects() {
        var tabs = PRTabs()
        tabs.open(pr(1), in: project)
        tabs.open(pr(2), in: other)
        tabs.keep(projects: [project])
        #expect(tabs.tabs.map(\.pr.number) == [1])
        #expect(tabs.activeID == PRTab.key(project, 1))
    }

    @Test("what was open comes back after a relaunch; a missing file is no tab")
    func store() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-pr-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PRTabsStore(directory: directory)
        #expect(store.load().isEmpty)

        var tabs = PRTabs()
        tabs.open(pr(1), in: project)
        tabs.show(pr(2), in: project)
        tabs.setSummary("Two things.", for: PRTab.key(project, 1))
        tabs.activate(PRTab.key(project, 1))
        store.save(tabs)

        let loaded = PRTabsStore(directory: directory).load()
        #expect(loaded == tabs)
        #expect(loaded.active?.reviewSummary == "Two things.")
        #expect(loaded.tabs[1].isPreview)

        try Data("{".utf8).write(to: directory.appendingPathComponent("pr-tabs.json"))
        #expect(PRTabsStore(directory: directory).load().isEmpty)
    }

    @Test("an active id that names no tab falls back to the first")
    func activeFallback() {
        let tabs = PRTabs(tabs: [PRTab(projectID: project, pr: pr(1))], activeID: "gone")
        #expect(tabs.activeID == PRTab.key(project, 1))
    }
}
