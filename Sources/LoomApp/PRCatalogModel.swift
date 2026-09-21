import Foundation
import LoomCore
import LoomGit
import LoomPersistence

/// The PRs tab beyond the projects: which GitHub repository each project is,
/// the organizations' catalog to add more from, the inbox of reviews waiting
/// on the user, the GitHub search, and the review drafts.
extension AppModel {

    // MARK: Project ↔ repository

    /// Looks up, once per project, the GitHub repository its `origin` names.
    /// Detached: a git process per project must not hold the reload.
    func resolveProjectRepoNames() {
        let missing = projects.filter {
            projectRepoNames[$0.id] == nil && !repoNameLookups.contains($0.id)
        }
        guard !missing.isEmpty else { return }
        repoNameLookups.formUnion(missing.map(\.id))
        Task {
            for project in missing {
                let remote = await GitService().remoteURL(in: URL(fileURLWithPath: project.path))
                projectRepoNames[project.id] = remote.flatMap(GitHubRepoName.parse(remoteURL:)) ?? ""
                repoNameLookups.remove(project.id)
            }
        }
    }

    /// `owner/name` for a project, nil until known or when it is no GitHub clone.
    public func repoName(for projectID: ProjectID) -> String? {
        guard let name = projectRepoNames[projectID], !name.isEmpty else { return nil }
        return name
    }

    /// The project cloning a repository, when there is one. GitHub names are
    /// case-insensitive; a remote may spell the owner differently.
    public func project(forRepo nameWithOwner: String) -> ProjectRecord? {
        projects.first { repoName(for: $0.id)?.caseInsensitiveCompare(nameWithOwner) == .orderedSame }
    }

    // MARK: Catalog — the organizations and their repositories

    /// Fetches only when nothing is cached or the cache is a day old.
    public func ensureCatalog() async {
        if let catalog, !catalog.isStale() { return }
        await refreshCatalog()
    }

    /// Fetches whatever the cache's age. A failed call leaves the cached
    /// catalog in place and says why — never an empty catalog stamped fresh.
    public func refreshCatalog() async {
        guard !catalogLoading else { return }
        catalogLoading = true
        defer { catalogLoading = false }
        let service = GitHubService()
        do {
            let viewer = try await service.viewerLogin()
            let organizations = try await service.organizations()
            var owners: [String: [GitHubService.Repository]] = [:]
            for owner in organizations + [viewer] {
                owners[owner] = try await service.repositories(owner: owner)
                    .sorted { $0.pushedAt > $1.pushedAt }
            }
            let entry = RepoCatalogCache.Entry(fetchedAt: Date(), viewer: viewer, owners: owners)
            catalog = entry
            catalogError = nil
            let cache = repoCatalogCache
            Task.detached(priority: .utility) { cache.save(entry) }
        } catch {
            catalogError = Self.ghErrorText(error)
        }
    }

    /// The owners to show, in the catalog's order, minus the hidden ones.
    public var visibleOwners: [String] {
        (catalog?.orderedOwners ?? []).filter { !hiddenOwners.contains($0) }
    }

    /// An owner's repositories worth listing: not hidden, not already a
    /// project (those live in the projects list, with their PRs).
    public func catalogRepositories(of owner: String) -> [GitHubService.Repository] {
        (catalog?.owners[owner] ?? []).filter {
            !hiddenRepos.contains($0.nameWithOwner) && project(forRepo: $0.nameWithOwner) == nil
        }
    }

    public var hiddenCount: Int { hiddenOwners.count + hiddenRepos.count }

    public func hide(owner: String) {
        hiddenOwners.insert(owner)
        UserDefaults.standard.set(Array(hiddenOwners).sorted(), forKey: "loom.pr.hiddenOwners")
    }

    public func hide(repo nameWithOwner: String) {
        hiddenRepos.insert(nameWithOwner)
        UserDefaults.standard.set(Array(hiddenRepos).sorted(), forKey: "loom.pr.hiddenRepos")
    }

    public func unhideAll() {
        hiddenOwners = []
        hiddenRepos = []
        UserDefaults.standard.removeObject(forKey: "loom.pr.hiddenOwners")
        UserDefaults.standard.removeObject(forKey: "loom.pr.hiddenRepos")
    }

    // MARK: Clone — a catalog repository becomes a project

    public func isCloning(_ nameWithOwner: String) -> Bool { cloning.contains(nameWithOwner) }

    /// Clones the repository through gh and registers the clone as a
    /// project — the one way a remote repository enters the PRs tab. The
    /// destination folder is asked for the first time, then remembered.
    /// Returns the project, or nil (cancelled, or the error is on the banner).
    @discardableResult
    public func addRepositoryAsProject(_ nameWithOwner: String) async -> ProjectID? {
        if let existing = project(forRepo: nameWithOwner) { return existing.id }
        guard !cloning.contains(nameWithOwner) else { return nil }
        var parent = cloneDirectory
        if parent == nil, let picked = Self.pickFolder(title: "Clone repositories into…") {
            cloneDirectory = picked
            parent = picked
        }
        guard let parent else { return nil }
        cloning.insert(nameWithOwner)
        defer { cloning.remove(nameWithOwner) }
        do {
            let url = try await GitHubService().clone(nameWithOwner, into: parent)
            let id = await addProject(at: url)
            projectRepoNames[id] = nameWithOwner
            return id
        } catch {
            startupError = "Could not clone \(nameWithOwner): \(Self.ghErrorText(error))"
            return nil
        }
    }

    /// The clone the view confirmed: clone, then open the PR it was for.
    /// Takes the value: the dialog's dismissal clears `pendingClone` before
    /// any task started from its button runs.
    public func confirmClone(_ pending: PendingClone?) async {
        guard let pending else { return }
        if pendingClone == pending { pendingClone = nil }
        guard let projectID = await addRepositoryAsProject(pending.repo) else { return }
        if let number = pending.number {
            await openPR(number, in: projectID, repo: pending.repo)
        }
    }

    // MARK: Opening a PR from outside a list — inbox, search, pasted URL

    /// Opens a PR of a repository named `owner/name`: in its project when one
    /// clones it, else after asking to clone it first.
    public func openPR(repo nameWithOwner: String, number: Int) async {
        if let project = project(forRepo: nameWithOwner) {
            await openPR(number, in: project.id, repo: nameWithOwner)
        } else {
            pendingClone = PendingClone(repo: nameWithOwner, number: number)
        }
    }

    /// A pasted URL or shorthand. A bare number means the selected project.
    public func openPR(reference: PRReference) async {
        if let repo = reference.repo {
            await openPR(repo: repo, number: reference.number)
        } else if let projectID = selectedProject ?? projects.first?.id {
            await openPR(reference.number, in: projectID, repo: repoName(for: projectID))
        } else {
            startupError = "Add a project first — a bare PR number needs a repository."
        }
    }

    /// Fetches the full row (the search knows neither branch nor checks) and
    /// hands it to the tab through the same channel a project row uses.
    private func openPR(_ number: Int, in projectID: ProjectID, repo nameWithOwner: String?) async {
        do {
            let pr: GitHubService.PullRequest?
            if let nameWithOwner {
                pr = try await GitHubService().pullRequest(number, repo: nameWithOwner)
            } else if let folder = projectRepo(projectID) {
                // No remote name known: gh resolves the repository from the folder.
                pr = try await GitHubService().pullRequest(number, repo: nil, in: folder)
            } else {
                pr = nil
            }
            guard let pr else {
                startupError = "Pull request #\(number) was not found."
                return
            }
            pendingPR = PendingPR(projectID: projectID, pr: pr)
        } catch {
            startupError = "Could not load PR #\(number): \(Self.ghErrorText(error))"
        }
    }

    // MARK: Inbox — reviews waiting on the user, everywhere

    static let inboxTTL: TimeInterval = 10 * 60

    public func ensureInbox() async {
        if let fetchedAt = inboxFetchedAt, Date().timeIntervalSince(fetchedAt) < Self.inboxTTL { return }
        await refreshInbox()
    }

    public func refreshInbox() async {
        guard !inboxLoading else { return }
        inboxLoading = true
        defer { inboxLoading = false }
        do {
            inbox = try await GitHubService().searchPRs(text: "", reviewRequestedToMe: true)
            inboxFetchedAt = Date()
            inboxError = nil
        } catch {
            inboxError = Self.ghErrorText(error)
        }
    }

    // MARK: GitHub search — across the visible organizations

    public func searchPRs(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearch(); return }
        // Two Returns in a row: only the latest search may paint — a slower
        // earlier one must not overwrite it.
        searchGeneration += 1
        let generation = searchGeneration
        searchLoading = true
        defer { if generation == searchGeneration { searchLoading = false } }
        do {
            let results = try await GitHubService().searchPRs(text: query, owners: visibleOwners)
            guard generation == searchGeneration else { return }
            searchResults = results
            searchError = nil
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            searchError = Self.ghErrorText(error)
        }
    }

    public func clearSearch() {
        searchResults = nil
        searchError = nil
    }

    // MARK: Review drafts — comments that wait for the verdict

    public func reviewDraft(for number: Int, in projectID: ProjectID) -> ReviewDraft? {
        reviewDrafts[prKey(number, projectID)]
    }

    /// Keeps a comment for the PR's review. The head the first comment was
    /// written on is remembered: a head that moved since is worth a warning.
    public func addDraftComment(_ comment: DraftComment, headSHA: String,
                                for number: Int, in projectID: ProjectID) {
        let key = prKey(number, projectID)
        let draft = reviewDrafts[key] ?? ReviewDraft(headSHA: headSHA)
        reviewDrafts[key] = draft.adding(comment)
        saveReviewDrafts()
    }

    public func removeDraftComment(_ id: UUID, for number: Int, in projectID: ProjectID) {
        let key = prKey(number, projectID)
        guard let draft = reviewDrafts[key] else { return }
        let remaining = draft.removing(id)
        reviewDrafts[key] = remaining.isEmpty ? nil : remaining
        saveReviewDrafts()
    }

    public func discardDraft(for number: Int, in projectID: ProjectID) {
        reviewDrafts[prKey(number, projectID)] = nil
        saveReviewDrafts()
    }

    func saveReviewDrafts() {
        let store = reviewDraftStore
        let drafts = reviewDrafts
        Task.detached(priority: .utility) { store.save(drafts) }
    }
}
