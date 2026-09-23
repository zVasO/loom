import LoomGit
import LoomUI
import Foundation

/// Parses, pairs and colours a PR's diff ONCE per diff text and scheme. The
/// products used to be view state: every tab activation, every ⌘⇧[ / ⌘⇧]
/// and every Sessions→PRs round trip re-parsed the diff, rebuilt the split
/// rows and ran highlight.js again — "Loading the diff…", then a plain→
/// coloured flip, seconds on a 5k-line PR (audit 2026-09-22, hot path 8).
/// Keyed by the model's PR key; a refreshed diff (new hash) replaces the
/// entry; identical concurrent requests share one computation.
actor DiffPipeline {

    struct Rows: Sendable {
        let hash: Int
        let parsed: [DiffParser.File]
        let files: [DiffFileRows]
    }

    private var rows: [String: Rows] = [:]
    private var rowsInFlight: [String: (hash: Int, task: Task<Rows, Never>)] = [:]
    /// Both palettes of a diff stay resident: an appearance flip is a hit,
    /// not a recomputation that evicts the other scheme.
    private var highlights: [String: [Bool: (hash: Int, value: DiffHighlights)]] = [:]
    private var highlightsInFlight: [String: [Bool: (hash: Int, task: Task<DiffHighlights, Never>)]] = [:]
    /// Bumped by every eviction: a computation that started before one must
    /// not put its product back once it lands.
    private var generation = 0

    /// The parsed files and split rows for `diff` — cached, or computed off
    /// the actor (it stays free for other PRs while a big one parses).
    func rows(for key: String, diff: String) async -> Rows {
        let hash = diff.hashValue
        if let cached = rows[key], cached.hash == hash { return cached }
        if let pending = rowsInFlight[key], pending.hash == hash { return await pending.task.value }
        let task = Task.detached(priority: .userInitiated) { () -> Rows in
            let parsed = DiffParser.parse(diff)
            return Rows(hash: hash, parsed: parsed, files: DiffFileRows.compute(parsed))
        }
        rowsInFlight[key] = (hash, task)
        let started = generation
        let result = await task.value
        if started == generation { rows[key] = result }
        if rowsInFlight[key]?.hash == hash { rowsInFlight[key] = nil }
        return result
    }

    /// The colours for `rows` in `dark` or light — cached per scheme, computed
    /// on the shared highlighters (an actor: waiters queue in its mailbox, no
    /// thread parks on a lock while a big PR colours).
    func highlights(for key: String, rows: Rows, dark: Bool) async -> DiffHighlights {
        if let cached = highlights[key]?[dark], cached.hash == rows.hash { return cached.value }
        if let pending = highlightsInFlight[key]?[dark], pending.hash == rows.hash {
            return await pending.task.value
        }
        let parsed = rows.parsed
        let task = Task.detached(priority: .utility) {
            await SharedHighlighters.shared.highlight(parsed, dark: dark)
        }
        highlightsInFlight[key, default: [:]][dark] = (rows.hash, task)
        let started = generation
        let value = await task.value
        if started == generation {
            // The other scheme's colours belong to the rows they were built
            // from: a new diff hash drops them too.
            var entries = (highlights[key] ?? [:]).filter { $0.value.hash == rows.hash }
            entries[dark] = (rows.hash, value)
            highlights[key] = entries
        }
        if highlightsInFlight[key]?[dark]?.hash == rows.hash { highlightsInFlight[key]?[dark] = nil }
        return value
    }

    /// Forgets every PR of a project (the model's key prefix) — what a list
    /// refresh does to the raw diff cache too.
    func evict(prefix: String) {
        generation += 1
        rows = rows.filter { !$0.key.hasPrefix(prefix) }
        highlights = highlights.filter { !$0.key.hasPrefix(prefix) }
    }
}
