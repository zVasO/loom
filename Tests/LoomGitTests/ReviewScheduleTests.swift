import Testing
import Foundation
import LoomCore
@testable import LoomGit

// A schedule runs at a time on chosen days, catches up on a run slept
// through, never runs one it was armed after, and picks the PRs nobody
// pushed to since the last scheduled review of them.
@Suite("ReviewSchedule — when a run is owed, and which PRs it takes")
struct ReviewScheduleTests {

    private let project = ProjectID()

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-26 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func schedule(armedAt: Date? = nil, lastRunAt: Date? = nil,
                          weekdays: Set<Int> = ReviewSchedule.workdays) -> ReviewSchedule {
        ReviewSchedule(hour: 9, minute: 0, weekdays: weekdays,
                       targets: [ReviewScheduleTarget(projectID: project)],
                       armedAt: armedAt ?? date(20, 12), lastRunAt: lastRunAt)
    }

    private func pr(_ number: Int, head: String = "", draft: Bool = false) -> GitHubService.PullRequest {
        GitHubService.PullRequest(number: number, title: "t", author: "a", branch: "b",
                                  baseBranch: "main", reviewDecision: "", checksPassing: true,
                                  isDraft: draft, updatedAt: "2026-10-26T08:00:00Z", url: "",
                                  headSHA: head)
    }

    @Test("the latest occurrence is today's when its time has passed, else the previous chosen day's")
    func latestOccurrence() {
        let weekdays = schedule()
        #expect(weekdays.latestOccurrence(atOrBefore: date(27, 9, 30), calendar: calendar) == date(27, 9))
        #expect(weekdays.latestOccurrence(atOrBefore: date(27, 8), calendar: calendar) == date(26, 9))
        #expect(weekdays.latestOccurrence(atOrBefore: date(26, 8), calendar: calendar) == date(23, 9),
                "Monday before nine: Friday's, the weekend is not chosen")
        #expect(weekdays.latestOccurrence(atOrBefore: date(27, 9), calendar: calendar) == date(27, 9),
                "the minute itself counts")
        #expect(schedule(weekdays: []).latestOccurrence(atOrBefore: date(27, 9), calendar: calendar) == nil)
    }

    @Test("the next occurrence skips the days not chosen")
    func nextOccurrence() {
        let weekdays = schedule()
        #expect(weekdays.nextOccurrence(after: date(23, 10), calendar: calendar) == date(26, 9),
                "Friday after nine: Monday")
        #expect(weekdays.nextOccurrence(after: date(27, 8), calendar: calendar) == date(27, 9))
        #expect(weekdays.nextOccurrence(after: date(27, 9), calendar: calendar) == date(28, 9),
                "strictly after")
    }

    @Test("a run is owed once per occurrence, within the catch-up window")
    func dueOccurrence() {
        let fresh = schedule()
        #expect(fresh.dueOccurrence(at: date(27, 9, 0), calendar: calendar) == date(27, 9))
        #expect(fresh.dueOccurrence(at: date(27, 12, 30), calendar: calendar) == date(27, 9),
                "a Mac asleep at nine still runs at half past twelve")
        #expect(fresh.dueOccurrence(at: date(27, 13, 30), calendar: calendar) == nil,
                "past the window: not the next afternoon's surprise batch")
        let ran = schedule(lastRunAt: date(27, 9, 0))
        #expect(ran.dueOccurrence(at: date(27, 10), calendar: calendar) == nil, "already ran")
        #expect(ran.dueOccurrence(at: date(28, 9, 1), calendar: calendar) == date(28, 9))
    }

    @Test("a schedule armed after today's time waits for the next one")
    func armedAfterTheTime() {
        let late = schedule(armedAt: date(27, 10))
        #expect(late.dueOccurrence(at: date(27, 10, 1), calendar: calendar) == nil)
        #expect(late.dueOccurrence(at: date(28, 9), calendar: calendar) == date(28, 9))
    }

    @Test("off, or with nothing to review, a schedule is never due")
    func neverDue() {
        var off = schedule()
        off.enabled = false
        #expect(off.dueOccurrence(at: date(27, 9), calendar: calendar) == nil)
        var empty = schedule()
        empty.targets = []
        #expect(empty.dueOccurrence(at: date(27, 9), calendar: calendar) == nil)
    }

    @Test("values out of range are clamped: a time, days, a slice's size")
    func clamping() {
        let odd = ReviewSchedule(hour: 30, minute: -5, weekdays: [0, 1, 8])
        #expect(odd.hour == 23)
        #expect(odd.minute == 0)
        #expect(odd.weekdays == [1])
        #expect(ReviewScheduleTarget(projectID: project, limit: 0).limit == 1)
        #expect(ReviewScheduleTarget(projectID: project, limit: 500).limit == ReviewScheduleTarget.maxLimit)
    }

    @Test("a slice's filter is its query, normalized, run in the project's repository")
    func targetFilter() {
        let target = ReviewScheduleTarget(projectID: project, query: "is:pr  review:none draft:false", limit: 3)
        #expect(target.filter.ghArguments(limit: target.fetchLimit)
                == ["--limit", "10", "--search", "review:none draft:false"])
        #expect(ReviewScheduleTarget(projectID: project).query == PRFilter.needsReview.query,
                "a new slice starts on the PRs needing review")
    }

    @Test("a run picks no draft, no PR reviewed at its head, none another slice took — at most the limit")
    func planner() {
        let prs = [pr(1, head: "a"), pr(2, head: "b", draft: true), pr(3, head: "c"), pr(4, head: "d"),
                   pr(5, head: "e")]
        let heads = [PRTab.key(project, 1): "a", PRTab.key(project, 3): "old"]
        let picked = ReviewSchedulePlanner.pick(prs, limit: 2, in: project, reviewedHeads: heads,
                                                taken: [PRTab.key(project, 4)])
        #expect(picked.map(\.number) == [3, 5],
                "1 is reviewed at its head, 2 is a draft, 3 moved since, 4 is another slice's")
    }

    @Test("a row without a head is measured by its last update")
    func fingerprint() {
        #expect(ReviewSchedulePlanner.fingerprint(pr(1, head: "abc")) == "abc")
        #expect(ReviewSchedulePlanner.fingerprint(pr(1)) == "updated:2026-10-26T08:00:00Z")
    }

    @Test("the state survives the disk; an unreadable file is no schedule")
    func store() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-schedules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReviewScheduleStore(directory: directory)
        #expect(store.load() == ReviewScheduleState())

        let state = ReviewScheduleState(schedules: [schedule(lastRunAt: date(27, 9))],
                                        reviewedHeads: [PRTab.key(project, 7): "abc"], maxConcurrent: 3)
        store.save(state)
        let loaded = store.load()
        #expect(loaded.schedules.map(\.id) == state.schedules.map(\.id))
        #expect(loaded.schedules.first?.targets == state.schedules.first?.targets)
        #expect(loaded.schedules.first?.lastRunAt == date(27, 9))
        #expect(loaded.reviewedHeads == state.reviewedHeads)
        #expect(loaded.maxConcurrent == 3)

        try Data("{\"schedules\": 12}".utf8).write(to: directory.appendingPathComponent("review-schedules.json"))
        #expect(store.load() == ReviewScheduleState())
        try Data("{}".utf8).write(to: directory.appendingPathComponent("review-schedules.json"))
        #expect(store.load().maxConcurrent == ReviewScheduleState.defaultConcurrency,
                "missing keys are defaults")
    }
}

@Suite("DiffParser.canAnchor — where GitHub takes a review comment")
struct DiffAnchorTests {

    private let files = DiffParser.parse("""
    diff --git a/src/cache.ts b/src/cache.ts
    --- a/src/cache.ts
    +++ b/src/cache.ts
    @@ -10,4 +10,5 @@ export function get() {
     const ttl = 60
    -return stale
    +if (fresh) return value
    +return refresh()
     }
    @@ -40,2 +41,2 @@
    -old
    +new
     tail
    """)

    @Test("a line of a hunk, on its side")
    func lines() {
        #expect(DiffParser.canAnchor(path: "src/cache.ts", firstLine: 11, lastLine: 11, side: "RIGHT", in: files))
        #expect(DiffParser.canAnchor(path: "src/cache.ts", firstLine: 10, lastLine: 10, side: "RIGHT", in: files),
                "context lines take comments too")
        #expect(DiffParser.canAnchor(path: "src/cache.ts", firstLine: 11, lastLine: 11, side: "LEFT", in: files),
                "the deleted line, in the old file")
        #expect(!DiffParser.canAnchor(path: "src/cache.ts", firstLine: 30, lastLine: 30, side: "RIGHT", in: files),
                "outside every hunk")
        #expect(!DiffParser.canAnchor(path: "src/other.ts", firstLine: 11, lastLine: 11, side: "RIGHT", in: files))
    }

    @Test("a range must sit in one hunk")
    func ranges() {
        #expect(DiffParser.canAnchor(path: "src/cache.ts", firstLine: 10, lastLine: 12, side: "RIGHT", in: files))
        #expect(!DiffParser.canAnchor(path: "src/cache.ts", firstLine: 12, lastLine: 41, side: "RIGHT", in: files),
                "two hunks")
        #expect(!DiffParser.canAnchor(path: "src/cache.ts", firstLine: 12, lastLine: 10, side: "RIGHT", in: files))
        #expect(!DiffParser.canAnchor(path: "src/cache.ts", firstLine: 0, lastLine: 0, side: "RIGHT", in: files))
    }
}
