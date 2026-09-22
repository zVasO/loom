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
    private var highlights: [String: (hash: Int, dark: Bool, value: DiffHighlights)] = [:]
    private var highlightsInFlight: [String: (hash: Int, dark: Bool, task: Task<DiffHighlights, Never>)] = [:]

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
        let result = await task.value
        rows[key] = result
        if rowsInFlight[key]?.hash == hash { rowsInFlight[key] = nil }
        return result
    }

    /// The colours for `rows` in `dark` or light — cached per scheme, computed
    /// off the actor on the shared highlighters.
    func highlights(for key: String, rows: Rows, dark: Bool) async -> DiffHighlights {
        if let cached = highlights[key], cached.hash == rows.hash, cached.dark == dark { return cached.value }
        if let pending = highlightsInFlight[key], pending.hash == rows.hash, pending.dark == dark {
            return await pending.task.value
        }
        let parsed = rows.parsed
        let task = Task.detached(priority: .utility) {
            SharedHighlighters.shared.highlight(parsed, dark: dark)
        }
        highlightsInFlight[key] = (rows.hash, dark, task)
        let value = await task.value
        highlights[key] = (rows.hash, dark, value)
        if let pending = highlightsInFlight[key], pending.hash == rows.hash, pending.dark == dark {
            highlightsInFlight[key] = nil
        }
        return value
    }

    /// Forgets every PR of a project (the model's key prefix) — what a list
    /// refresh does to the raw diff cache too.
    func evict(prefix: String) {
        rows = rows.filter { !$0.key.hasPrefix(prefix) }
        highlights = highlights.filter { !$0.key.hasPrefix(prefix) }
    }
}
