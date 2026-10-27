import Foundation
import LoomCore

/// A review run the app starts on its own: at a time of day, on chosen days,
/// over a few slices of the projects' pull requests — every PR needing review
/// in one repository, the three most recent waiting on me in another. Each PR
/// it picks gets the same review a click on "Start review" gives, and a full
/// review prompt after the brief; the human reads the result and decides.
public struct ReviewSchedule: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty = never.
    public var weekdays: Set<Int>
    public var targets: [ReviewScheduleTarget]
    /// When the schedule was armed: created, or its time or days changed. A
    /// time already past at that moment is not a run it missed.
    public var armedAt: Date
    public var lastRunAt: Date?
    /// A workflow (ADR-0017) each picked PR runs instead of the built-in
    /// full review; nil keeps the built-in one.
    public var workflowID: UUID?

    public init(id: UUID = UUID(), name: String = "Morning reviews", enabled: Bool = true,
                hour: Int = 9, minute: Int = 0, weekdays: Set<Int> = ReviewSchedule.workdays,
                targets: [ReviewScheduleTarget] = [], armedAt: Date = Date(),
                lastRunAt: Date? = nil, workflowID: UUID? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.targets = targets
        self.armedAt = armedAt
        self.lastRunAt = lastRunAt
        self.workflowID = workflowID
    }

    /// Monday to Friday.
    public static let workdays: Set<Int> = [2, 3, 4, 5, 6]

    /// How late a run may still start: a Mac asleep at 9:00 and opened at
    /// 10:30 still reviews; one opened the next afternoon does not run
    /// yesterday's batch on top of today's.
    public static let catchUpWindow: TimeInterval = 4 * 3600

    /// The latest scheduled moment at or before `now`, over the past week.
    public func latestOccurrence(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        for back in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  time <= now else { continue }
            return time
        }
        return nil
    }

    /// The next scheduled moment strictly after `now` — what the UI announces.
    public func nextOccurrence(after now: Date, calendar: Calendar = .current) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        for ahead in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  time > now else { continue }
            return time
        }
        return nil
    }

    /// The occurrence a run is owed for, or nil: past, later than both the
    /// last run and the arming, and within the catch-up window.
    public func dueOccurrence(at now: Date, catchUp: TimeInterval = ReviewSchedule.catchUpWindow,
                              calendar: Calendar = .current) -> Date? {
        guard enabled, !targets.isEmpty,
              let latest = latestOccurrence(atOrBefore: now, calendar: calendar) else { return nil }
        let floor = max(armedAt, lastRunAt ?? .distantPast)
        guard latest > floor, now.timeIntervalSince(latest) <= catchUp else { return nil }
        return latest
    }
}

/// One slice of a schedule: a project's pull requests through a GitHub
/// search query — the syntax a PR filter takes — and how many of them a run
/// reviews at most.
public struct ReviewScheduleTarget: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var projectID: ProjectID
    /// Search qualifiers, one line (`review:none draft:false`).
    public var query: String
    /// At most this many PRs reviewed per run from this slice.
    public var limit: Int

    public init(id: UUID = UUID(), projectID: ProjectID,
                query: String = PRFilter.needsReview.query, limit: Int = 5) {
        self.id = id
        self.projectID = projectID
        self.query = query
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    /// Each review is a claude session reading a whole PR: a slice is a
    /// handful, not a backlog.
    public static let maxLimit = 20

    /// The query as a filter `gh pr list` runs.
    public var filter: PRFilter {
        PRFilter(id: "schedule-\(id.uuidString)", name: "Scheduled",
                 query: PRFilter.normalizedQuery(query), isBuiltIn: false)
    }

    /// Fetched beyond the limit: the PRs already reviewed at their head are
    /// skipped, and the next ones take their place.
    public var fetchLimit: Int { min(max(limit * 3, 10), PRFilter.defaultLimit) }
}

/// Which PRs a run reviews — pure, so the rules are tested, not observed.
public enum ReviewSchedulePlanner {

    /// What "already reviewed" is measured against: the head commit, or the
    /// last update when a row carries no head.
    public static func fingerprint(_ pr: GitHubService.PullRequest) -> String {
        pr.headSHA.isEmpty ? "updated:" + pr.updatedAt : pr.headSHA
    }

    /// The PRs a slice hands to a run, in gh's order: never a draft, never
    /// one a scheduled review already covered at this head, never one
    /// another slice of the same run took — at most `limit`.
    public static func pick(_ prs: [GitHubService.PullRequest], limit: Int, in projectID: ProjectID,
                            reviewedHeads: [String: String],
                            taken: Set<String>) -> [GitHubService.PullRequest] {
        var picked: [GitHubService.PullRequest] = []
        for pr in prs where picked.count < limit && !pr.isDraft {
            let key = PRTab.key(projectID, pr.number)
            guard !taken.contains(key), reviewedHeads[key] != fingerprint(pr) else { continue }
            picked.append(pr)
        }
        return picked
    }
}

/// The schedules and what their runs remember, in one file next to the PR
/// cache. Disposable: unreadable means no schedule, never an error.
public struct ReviewScheduleState: Codable, Equatable, Sendable {
    public var schedules: [ReviewSchedule]
    /// `<project>#<number>` → the head a scheduled review last covered: the
    /// next run skips a PR nobody pushed to since.
    public var reviewedHeads: [String: String]
    /// Reviews running at once: each one is a claude session at work.
    public var maxConcurrent: Int

    public init(schedules: [ReviewSchedule] = [], reviewedHeads: [String: String] = [:],
                maxConcurrent: Int = ReviewScheduleState.defaultConcurrency) {
        self.schedules = schedules
        self.reviewedHeads = reviewedHeads
        self.maxConcurrent = min(max(maxConcurrent, 1), Self.maxConcurrency)
    }

    public static let defaultConcurrency = 2
    public static let maxConcurrency = 6

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schedules: try container.decodeIfPresent([ReviewSchedule].self, forKey: .schedules) ?? [],
            reviewedHeads: try container.decodeIfPresent([String: String].self, forKey: .reviewedHeads) ?? [:],
            maxConcurrent: try container.decodeIfPresent(Int.self, forKey: .maxConcurrent)
                ?? Self.defaultConcurrency)
    }
}

public struct ReviewScheduleStore: Sendable {
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("review-schedules.json")
    }

    public func load() -> ReviewScheduleState {
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode(ReviewScheduleState.self, from: data)
        else { return ReviewScheduleState() }
        return state
    }

    public func save(_ state: ReviewScheduleState) {
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
