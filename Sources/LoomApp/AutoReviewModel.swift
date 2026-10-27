import Foundation
import LoomAgents
import LoomCore
import LoomGit
import UserNotifications

/// One run of a review schedule: the PRs it picked and where each stands.
/// Lives as long as the app — the tabs, drafts and summaries it fills are
/// what outlives it.
public struct AutoReviewRun: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case queued
        /// Worktree, session, `/setup-pr-review`.
        case preparing
        case reviewing
        /// The session asked something (a permission, a question): the run
        /// went on without it, and imports its report if it comes.
        case waitingOnYou
        /// Report imported: the suggested verdict, the comments drafted on
        /// diff lines, the findings folded into the summary.
        case ready(verdict: String, comments: Int, inSummary: Int)
        /// The session finished without a report Loom could read: its
        /// conversation, in the drawer, is the review.
        case noReport
        case failed(String)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        public var isSettled: Bool {
            switch self {
            case .queued, .preparing, .reviewing, .waitingOnYou: false
            case .ready, .noReport, .failed: true
            }
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        /// The PR's tab key, `<project>#<number>`.
        public var id: String { PRTab.key(projectID, pr.number) }
        public let projectID: ProjectID
        public let pr: GitHubService.PullRequest
        public var status: Status = .queued
        public var sessionID: SessionID?
    }

    public let id = UUID()
    public let scheduleName: String
    public let startedAt: Date
    /// Every PR has had its turn — some may still wait on the user.
    public var finishedAt: Date?
    public var items: [Item] = []
    /// PRs left out because a scheduled review already covered their head.
    public var skipped = 0
    /// What kept a slice from being listed — a project gone, gh failing.
    public var errors: [String] = []

    public var isRunning: Bool { finishedAt == nil }
}

extension AppModel {

    var reviewScheduleStore: ReviewScheduleStore { ReviewScheduleStore(directory: supportDirectory) }

    /// How long one review may run before Loom stops waiting on it.
    static let autoReviewTimeout: Duration = .seconds(45 * 60)
    /// How long a review that handed itself to the user is still watched for
    /// its report.
    static let autoReviewHandOverTimeout: Duration = .seconds(12 * 3600)

    // MARK: Schedules — what Settings edits

    /// Loads the schedules and starts the clock. The first look waits for
    /// the launch to settle (sessions restored, caches read).
    func startReviewSchedules() {
        reviewSchedules = reviewScheduleStore.load()
        reviewScheduleClock?.cancel()
        reviewScheduleClock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15), clock: .continuous)
            while !Task.isCancelled {
                await self?.runDueReviewSchedules()
                // The continuous clock counts the Mac's sleep: the first tick
                // after a wake catches up on a 9:00 slept through.
                try? await Task.sleep(for: .seconds(30), clock: .continuous)
            }
        }
    }

    func saveReviewSchedules() {
        let store = reviewScheduleStore
        let state = reviewSchedules
        Task.detached(priority: .utility) { store.save(state) }
    }

    /// A new schedule, on the selected project's PRs needing review.
    @discardableResult
    public func addReviewSchedule() -> ReviewSchedule {
        let projectID = selectedProject ?? projects.first?.id
        let schedule = ReviewSchedule(
            name: reviewSchedules.schedules.isEmpty ? "Morning reviews" : "Reviews",
            targets: projectID.map { [ReviewScheduleTarget(projectID: $0)] } ?? [])
        reviewSchedules.schedules.append(schedule)
        saveReviewSchedules()
        return schedule
    }

    /// A schedule edited in Settings. A new time or new days re-arm it: a
    /// time already past today is tomorrow's, not a run owed now.
    public func updateReviewSchedule(_ schedule: ReviewSchedule) {
        guard let index = reviewSchedules.schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        var updated = schedule
        let old = reviewSchedules.schedules[index]
        if old.hour != schedule.hour || old.minute != schedule.minute || old.weekdays != schedule.weekdays
            || (!old.enabled && schedule.enabled) {
            updated.armedAt = Date()
        }
        reviewSchedules.schedules[index] = updated
        saveReviewSchedules()
    }

    public func removeReviewSchedule(_ id: UUID) {
        reviewSchedules.schedules.removeAll { $0.id == id }
        saveReviewSchedules()
    }

    public func setAutoReviewConcurrency(_ count: Int) {
        reviewSchedules.maxConcurrent = min(max(count, 1), ReviewScheduleState.maxConcurrency)
        saveReviewSchedules()
    }

    /// The scheduled reviews forget which heads they covered: the next run
    /// reviews every PR its slices pick again.
    public func forgetAutoReviewedHeads() {
        reviewSchedules.reviewedHeads = [:]
        saveReviewSchedules()
    }

    /// The prompt typed after `/setup-pr-review`: the user's, else nil (the
    /// default). Stored only when it differs from the default.
    public var autoReviewPromptTemplate: String? {
        get { UserDefaults.standard.string(forKey: "loom.review.autoPrompt") }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty || trimmed == AutoReviewPrompt.defaultTemplate {
                UserDefaults.standard.removeObject(forKey: "loom.review.autoPrompt")
            } else {
                UserDefaults.standard.set(newValue, forKey: "loom.review.autoPrompt")
            }
        }
    }

    /// When the next scheduled run starts, across the enabled schedules.
    public func nextAutoReviewDate(after now: Date = Date()) -> Date? {
        reviewSchedules.schedules
            .filter { $0.enabled && !$0.targets.isEmpty }
            .compactMap { $0.nextOccurrence(after: now) }
            .min()
    }

    // MARK: Running

    /// The clock's tick: the first schedule owed a run starts it — one run
    /// at a time; another one due waits for this one to end.
    func runDueReviewSchedules(now: Date = Date()) async {
        guard manager != nil, autoReviewRun?.isRunning != true, GitHubService.isAvailable,
              let schedule = reviewSchedules.schedules.first(where: { $0.dueOccurrence(at: now) != nil })
        else { return }
        markReviewScheduleRan(schedule.id, at: now)
        await runReviewSchedule(schedule)
    }

    /// "Run now", from Settings or the PRs sidebar.
    public func runReviewScheduleNow(_ id: UUID) {
        guard autoReviewRun?.isRunning != true,
              let schedule = reviewSchedules.schedules.first(where: { $0.id == id }) else { return }
        markReviewScheduleRan(id, at: Date())
        Task { await runReviewSchedule(schedule) }
    }

    /// Stamped BEFORE the run: a tick during it must not start it twice.
    private func markReviewScheduleRan(_ id: UUID, at date: Date) {
        guard let index = reviewSchedules.schedules.firstIndex(where: { $0.id == id }) else { return }
        reviewSchedules.schedules[index].lastRunAt = date
        saveReviewSchedules()
    }

    /// Lists every slice, then reviews the PRs picked, a few at a time.
    func runReviewSchedule(_ schedule: ReviewSchedule) async {
        guard autoReviewRun?.isRunning != true else { return }
        let run = AutoReviewRun(scheduleName: schedule.name, startedAt: Date())
        autoReviewRun = run
        var taken = Set<String>()
        for target in schedule.targets {
            guard let project = project(target.projectID), let repo = projectRepo(target.projectID) else {
                autoReviewRun?.errors.append("A project of “\(schedule.name)” is no longer in Loom.")
                continue
            }
            do {
                let prs = try await GitHubService().listPRs(in: repo, filter: target.filter,
                                                            limit: target.fetchLimit)
                let heads = reviewSchedules.reviewedHeads
                let picked = ReviewSchedulePlanner.pick(prs, limit: target.limit, in: target.projectID,
                                                        reviewedHeads: heads, taken: taken)
                autoReviewRun?.skipped += prs.filter {
                    !$0.isDraft && heads[PRTab.key(target.projectID, $0.number)]
                        == ReviewSchedulePlanner.fingerprint($0)
                }.count
                for pr in picked {
                    taken.insert(PRTab.key(target.projectID, pr.number))
                    autoReviewRun?.items.append(AutoReviewRun.Item(projectID: target.projectID, pr: pr))
                }
            } catch {
                autoReviewRun?.errors.append("\(project.name): \(Self.ghErrorText(error))")
            }
        }
        let items = autoReviewRun?.items ?? []
        let width = reviewSchedules.maxConcurrent
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(width, items.count) {
                let item = items[next]
                group.addTask { await self.autoReview(item, run: run.id) }
                next += 1
            }
            while await group.next() != nil {
                guard next < items.count else { continue }
                let item = items[next]
                group.addTask { await self.autoReview(item, run: run.id) }
                next += 1
            }
        }
        guard autoReviewRun?.id == run.id else { return }
        autoReviewRun?.finishedAt = Date()
        notifyRunFinished()
    }

    private func updateAutoReviewItem(_ itemID: String, run runID: UUID,
                                      _ change: (inout AutoReviewRun.Item) -> Void) {
        guard autoReviewRun?.id == runID,
              let index = autoReviewRun?.items.firstIndex(where: { $0.id == itemID }) else { return }
        change(&autoReviewRun!.items[index])
    }

    /// One PR: its tab opened (pinned, in the background), its review
    /// session started or reattached with `/setup-pr-review`, the full review
    /// asked for, then waited on until claude writes its report.
    private func autoReview(_ item: AutoReviewRun.Item, run runID: UUID) async {
        let pr = item.pr
        let projectID = item.projectID
        updateAutoReviewItem(item.id, run: runID) { $0.status = .preparing }
        prTabs.openInBackground(pr, in: projectID)
        savePRTabs()
        guard let repo = projectRepo(projectID) else {
            updateAutoReviewItem(item.id, run: runID) { $0.status = .failed("The project folder is missing.") }
            return
        }
        // A report left by an earlier run must not pass for this one's.
        let report = GitHubService.reviewWorktreePath(pr.number, repo: repo)
            .appendingPathComponent(AutoReviewPrompt.reportRelativePath)
        try? FileManager.default.removeItem(at: report)
        let prompt = AutoReviewPrompt.render(
            template: autoReviewPromptTemplate,
            pr: .init(number: pr.number, title: pr.title, url: pr.url,
                      base: pr.baseBranch.isEmpty ? "main" : pr.baseBranch, head: pr.branch))
        guard let sessionID = await sendToPRReviewSession(prompt, pr: pr, in: projectID) else {
            let reason = startupError ?? "Its review session could not start."
            updateAutoReviewItem(item.id, run: runID) { $0.status = .failed(reason) }
            return
        }
        setPRTabDrawer(open: true, for: item.id)
        updateAutoReviewItem(item.id, run: runID) {
            $0.status = .reviewing
            $0.sessionID = sessionID
        }
        let outcome = await awaitAutoReview(sessionID, report: report, timeout: Self.autoReviewTimeout,
                                            handsOver: true)
        if case .needsYou = outcome {
            updateAutoReviewItem(item.id, run: runID) { $0.status = .waitingOnYou }
            // The slot goes to the next PR; this one is still watched.
            Task { [weak self] in
                guard let self else { return }
                let late = await self.awaitAutoReview(sessionID, report: report,
                                                      timeout: Self.autoReviewHandOverTimeout,
                                                      handsOver: false)
                await self.settleAutoReview(item, run: runID, outcome: late)
            }
            return
        }
        await settleAutoReview(item, run: runID, outcome: outcome)
    }

    enum AutoReviewOutcome {
        case report(AutoReviewReport)
        /// The session waits on the user (permission, question).
        case needsYou
        /// Idle a while, no readable report.
        case noReport
        /// The session is gone.
        case ended
        case timedOut
    }

    private func awaitAutoReview(_ id: SessionID, report: URL, timeout: Duration,
                                 handsOver: Bool) async -> AutoReviewOutcome {
        let outcome = await awaitSessionReport(id, file: report, timeout: timeout, handsOver: handsOver,
                                               parse: AutoReviewReport.parse)
        switch outcome {
        case .report(let parsed): return .report(parsed)
        case .needsYou: return .needsYou
        case .noReport: return .noReport
        case .ended: return .ended
        case .timedOut: return .timedOut
        }
    }

    /// How waiting on a session's report ended.
    enum SessionReportOutcome<Report> {
        case report(Report)
        /// The session waits on the user (permission, question).
        case needsYou
        /// Idle a while, no readable report.
        case noReport
        /// The session is gone.
        case ended
        case timedOut
    }

    /// Polls a session and the file it was asked to write: done once the
    /// file reads and claude stopped working on it. A session idle for
    /// minutes without one answered in the conversation, or nowhere. Shared
    /// by scheduled reviews and the workflows' visible steps.
    func awaitSessionReport<Report>(_ id: SessionID, file: URL, timeout: Duration, handsOver: Bool,
                                    parse: (String) -> Report?) async -> SessionReportOutcome<Report> {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var idleSince: ContinuousClock.Instant?
        var askingSince: ContinuousClock.Instant?
        while clock.now < deadline, !Task.isCancelled {
            let state = sessions.first { $0.id == id }?.state
            if state != .working, state != .starting,
               let text = try? String(contentsOf: file, encoding: .utf8),
               let parsed = parse(text) {
                return .report(parsed)
            }
            switch state {
            case .working?, .starting?, .draft?:
                idleSince = nil
                askingSince = nil
            case .needsInput?:
                idleSince = nil
                let since = askingSince ?? clock.now
                askingSince = since
                // A permission prompt answered by a hook a beat later is not
                // a hand-over: only one that stays.
                if handsOver, clock.now - since > .seconds(20) { return .needsYou }
            case .idle?:
                askingSince = nil
                let since = idleSince ?? clock.now
                idleSince = since
                if clock.now - since > .seconds(180) { return .noReport }
            case nil, .completed?, .failed?, .interrupted?, .archived?:
                return .ended
            }
            try? await Task.sleep(for: .seconds(3))
        }
        return .timedOut
    }

    /// The outcome on the PR: the report imported into its tab, or why not.
    private func settleAutoReview(_ item: AutoReviewRun.Item, run runID: UUID,
                                  outcome: AutoReviewOutcome) async {
        let status: AutoReviewRun.Status
        switch outcome {
        case .report(let report):
            let counts = await importReviewReport(report, pr: item.pr, in: item.projectID)
            status = .ready(verdict: report.verdict.rawValue, comments: counts.anchored,
                            inSummary: counts.unanchored)
            notifyReviewReady(item.pr, verdict: report.verdict, comments: counts.anchored)
        case .needsYou:
            status = .waitingOnYou
        case .noReport:
            status = .noReport
        case .ended:
            status = .failed("The session ended before writing its review.")
        case .timedOut:
            status = .noReport
        }
        updateAutoReviewItem(item.id, run: runID) { $0.status = status }
    }

    /// The report into the PR's tab: comments on diff lines become pending
    /// comments of the review, the others go into the summary, the verdict
    /// is shown as a suggestion. A summary the user already wrote is kept.
    func importReviewReport(_ report: AutoReviewReport, pr: GitHubService.PullRequest,
                                  in projectID: ProjectID) async -> (anchored: Int, unanchored: Int) {
        let diff = await prDiff(pr.number, baseBranch: pr.baseBranch, in: projectID, refresh: true).diff
        let files = DiffParser.parse(diff)
        var anchored = 0
        var unanchored: [AutoReviewReport.Comment] = []
        for comment in report.comments {
            if DiffParser.canAnchor(path: comment.path, firstLine: comment.firstLine,
                                    lastLine: comment.lastLine, side: comment.side, in: files) {
                addDraftComment(DraftComment(path: comment.path, firstLine: comment.firstLine,
                                             lastLine: comment.lastLine, side: comment.side,
                                             body: comment.body),
                                headSHA: pr.headSHA, for: pr.number, in: projectID)
                anchored += 1
            } else {
                unanchored.append(comment)
            }
        }
        let tabID = PRTab.key(projectID, pr.number)
        let summary = AutoReviewReport.summary(report.summary, unanchored: unanchored)
        if (prTabs.tab(tabID)?.reviewSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prTabs.setSummary(summary, for: tabID)
        }
        prTabs.setSuggestedVerdict(report.verdict.rawValue, for: tabID)
        savePRTabs()
        // The workspace on screen re-reads its draft and its summary.
        prReloadGenerations[tabID, default: 0] += 1
        reviewSchedules.reviewedHeads[tabID] = ReviewSchedulePlanner.fingerprint(pr)
        saveReviewSchedules()
        return (anchored, unanchored.count)
    }

    // MARK: Notifications

    private func notifyReviewReady(_ pr: GitHubService.PullRequest, verdict: AutoReviewReport.Verdict,
                                   comments: Int) {
        let detail = comments == 0 ? "no line comment" : comments == 1 ? "1 line comment" : "\(comments) line comments"
        postAutoReviewNotification(title: "PR #\(pr.number) reviewed",
                                   body: "\(pr.title)\nSuggests: \(verdict.label) · \(detail)",
                                   id: "loom.autoReview.\(pr.url)")
    }

    private func notifyRunFinished() {
        guard let run = autoReviewRun else { return }
        let ready = run.items.filter(\.status.isReady).count
        let waiting = run.items.filter { $0.status == .waitingOnYou }.count
        var parts = ["\(ready) of \(run.items.count) ready to read"]
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if !run.errors.isEmpty { parts.append("\(run.errors.count) error(s)") }
        let body = run.items.isEmpty
            ? (run.errors.first ?? "No pull request to review.")
            : parts.joined(separator: " · ")
        postAutoReviewNotification(title: run.scheduleName, body: body, id: "loom.autoReview.run.\(run.id)")
    }

    func postAutoReviewNotification(title: String, body: String, id: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // swift run without a bundle
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
