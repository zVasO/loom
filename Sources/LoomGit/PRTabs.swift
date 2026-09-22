import Foundation
import LoomCore

/// One open pull request in the PRs tab. A tab is either a PREVIEW — the
/// one the next click in the list reuses — or pinned: started a review,
/// double-clicked, or pinned by hand. Its drawer and its review summary
/// travel with it, across the app's tabs and across relaunches.
public struct PRTab: Codable, Equatable, Identifiable, Sendable {
    /// `<project uuid>#<number>` — the same key the model uses everywhere.
    public var id: String { PRTab.key(projectID, pr.number) }
    public let projectID: ProjectID
    public var pr: GitHubService.PullRequest
    public var isPreview: Bool
    /// The review session's drawer, open or not, for THIS tab.
    public var drawerOpen: Bool
    /// What the verdict bar holds — a review summary is written over time.
    public var reviewSummary: String

    public init(projectID: ProjectID, pr: GitHubService.PullRequest, isPreview: Bool = true,
                drawerOpen: Bool = false, reviewSummary: String = "") {
        self.projectID = projectID
        self.pr = pr
        self.isPreview = isPreview
        self.drawerOpen = drawerOpen
        self.reviewSummary = reviewSummary
    }

    public static func key(_ projectID: ProjectID, _ number: Int) -> String {
        "\(projectID.rawValue.uuidString)#\(number)"
    }
}

/// The open tabs and the active one. Pure, like `BrowserTabsModel`: the view
/// renders it, the model persists it.
public struct PRTabs: Codable, Equatable, Sendable {
    public private(set) var tabs: [PRTab] = []
    public private(set) var activeID: String?

    public init() {}

    public init(tabs: [PRTab], activeID: String?) {
        self.tabs = tabs
        self.activeID = tabs.contains { $0.id == activeID } ? activeID : tabs.first?.id
    }

    public var isEmpty: Bool { tabs.isEmpty }

    public var active: PRTab? { tabs.first { $0.id == activeID } }

    public func tab(_ id: String) -> PRTab? { tabs.first { $0.id == id } }

    public func contains(_ id: String) -> Bool { tabs.contains { $0.id == id } }

    // MARK: Opening

    /// A click in the list: the PR's own tab when it has one, else the
    /// preview tab — replaced in place, so browsing never piles tabs up —
    /// or a new preview when none exists. Active either way.
    public mutating func show(_ pr: GitHubService.PullRequest, in projectID: ProjectID) {
        let key = PRTab.key(projectID, pr.number)
        if let index = tabs.firstIndex(where: { $0.id == key }) {
            tabs[index].pr = pr
            activeID = key
            return
        }
        let tab = PRTab(projectID: projectID, pr: pr, isPreview: true)
        if let preview = tabs.firstIndex(where: \.isPreview) {
            tabs[preview] = tab
        } else {
            tabs.append(tab)
        }
        activeID = key
    }

    /// Shown AND pinned — a review starts, a row is double-clicked.
    public mutating func open(_ pr: GitHubService.PullRequest, in projectID: ProjectID) {
        show(pr, in: projectID)
        pin(PRTab.key(projectID, pr.number))
    }

    public mutating func pin(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPreview = false
    }

    // MARK: Closing and moving

    /// Closing the active tab lands on its right neighbour, else the left.
    public mutating func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if activeID == id {
            activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    public mutating func closeOthers(_ id: String) {
        guard let kept = tab(id) else { return }
        tabs = [kept]
        activeID = id
    }

    public mutating func activate(_ id: String) {
        guard contains(id) else { return }
        activeID = id
    }

    public mutating func activateNext() { step(by: 1) }

    public mutating func activatePrevious() { step(by: -1) }

    private mutating func step(by offset: Int) {
        guard !tabs.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.id == activeID }) else {
            activeID = tabs.first?.id
            return
        }
        activeID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    // MARK: Per-tab state

    public mutating func setDrawer(open: Bool, for id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].drawerOpen = open
    }

    public mutating func setSummary(_ summary: String, for id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].reviewSummary = summary
    }

    /// A list was refetched: the open tabs of that project take the fresh
    /// row (title, head, checks, review state). Everything else on the tab
    /// is the user's and stays.
    public mutating func refresh(from prs: [GitHubService.PullRequest], in projectID: ProjectID) {
        for (index, tab) in tabs.enumerated() where tab.projectID == projectID {
            if let fresh = prs.first(where: { $0.number == tab.pr.number }) {
                tabs[index].pr = fresh
            }
        }
    }

    /// Tabs of projects that no longer exist are dropped.
    public mutating func keep(projects: Set<ProjectID>) {
        tabs.removeAll { !projects.contains($0.projectID) }
        if let activeID, !contains(activeID) { self.activeID = tabs.first?.id }
    }
}

/// The tabs on disk, next to the PR cache: a relaunch reopens what was
/// open. Disposable — unreadable means no tab, never an error.
public struct PRTabsStore: Sendable {
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("pr-tabs.json")
    }

    public func load() -> PRTabs {
        guard let data = try? Data(contentsOf: url),
              let tabs = try? JSONDecoder().decode(PRTabs.self, from: data)
        else { return PRTabs() }
        return tabs
    }

    public func save(_ tabs: PRTabs) {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
