# Performance audit — 2026-08-17

Context: perceptible lag reported on a second (older) Mac. The app's job is
to make dev work smoother, not the opposite. Measurements below were taken
on an M-series Mac via `swift test --filter PerfProbes`; an older or Intel
machine multiplies every number by 2–4×.

## Measured facts

| # | Path | Measured cost | Frequency |
|---|------|---------------|-----------|
| 1 | `SessionRuntime.deliverFrame` → `engine.historyTail(400)` | **14.7 ms / frame** | every output chunk (uncapped) |
| 2 | `engine.snapshot()` (100×40) | 2.2 ms / frame | every output chunk |
| 3 | View-side `AttributedString` build, per-cell append (40×100) | 6.5 ms / screen | every frame, main thread |
| 4 | Same, batched into style runs | 0.35 ms / screen | — (candidate fix, **18×**) |
| 5 | `[TerminalLine]` ×400 history equality (SwiftUI diff) | 1.6 ms / compare | every frame, main thread |
| 6 | `ClaudeNativeSessions.exists()` miss (10 project dirs) | 0.34 ms / record | × N records × every reload |

## Root cause of the felt lag

**Frames are produced at network-chunk rate with no ceiling.** Each chunk
during claude streaming triggers: transcript append + engine feed +
`snapshot()` (2.2 ms) + `historyTail(400)` (14.7 ms) on the session queue,
then a full SwiftUI rebuild on the main thread (6.5 ms of AttributedString
appends + 1.6 ms of history diffing + `scrollTo` layout). At 30–60
chunks/s the session queue and the main thread saturate; typing latency
and beachballs follow. On an older Mac the same pipeline exceeds one core
several times over.

## Secondary findings (static analysis)

- **FTS query inside `body`**: the ⌘K palette calls
  `model.searchTranscripts(query)` during view evaluation — a synchronous
  SQLite FTS query per keystroke *and* per unrelated re-render.
- **Filesystem in `body`**: Project tabs call `skills(forProject:)`,
  `ruleFiles(for:)`, `listFiles(in:)` at render time (directory scans and
  file reads on the main thread, re-run on every render).
- **Startup reindex on the main actor**: `reindexAllSessions()` reads up
  to 2 MB per session transcript synchronously at launch.
- **Index-on-close on the main actor**: same reads when a session ends.
- **`reloadPersistedSessions` per transition**: full table read + one
  `exists()` directory scan per interrupted/history record, on every
  state-transition close and several other paths.
- **Mission Control**: N attached surfaces = N uncapped frame streams;
  `MiniTerminalPreview` maps *all* screen lines to Strings per frame then
  keeps 22; `FleetCard` reads the whole native `.jsonl` (can be MBs) on
  the main actor.
- **`emitSample`** builds a full `snapshot()` every 500 ms per session
  just to read a tail of trimmed lines.
- **Leftover shared `FileTranscriptSink`** (with its 250 ms timer) is
  still created although per-session sinks replaced it.
- **`saveStackChildren()` on every page visit** (browser navigation).
- **macOS 14 fallback** keeps the terminal pinned-to-bottom always → a
  `scrollTo` per revision even while the user scrolls up.

## Action plan (by measured impact)

### P0 — the streaming hot path (fixes the felt lag)
1. **Cap the frame rate**: coalesce `scheduleFrame` to at most one
   delivery per ~33 ms (leading edge immediate, trailing edge scheduled).
   Bounds every downstream cost; single-site change on the session queue.
2. **Stop rebuilding the scrollback tail per frame**: `historyTail` only
   changes when lines scroll off screen. Track the scrollback row count;
   rebuild only the *new* lines and append to a cached tail (14.7 ms → ~0
   on steady frames).
3. **Batch AttributedString by style runs** in `TerminalScreenView`
   (measured 18×), and **cache history-row AttributedStrings** — history
   lines are immutable once produced.
4. **Stable identity for history rows** (absolute scrollback index instead
   of `enumerated().offset`) so SwiftUI stops diffing 400 lines per frame.

### P1 — main-thread I/O off the render path
5. Palette: debounce the FTS query (~150 ms) into `@State` via
   `.task(id: query)` — never query inside `body`.
6. Move `reindexAllSessions` / `indexSessionForSearch` reads off the main
   actor (GRDB's queue is thread-safe).
7. Project tabs: load skills/rules/files into `@State` via `.task`, not in
   `body`.
8. `FleetCard`: read only the tail of the native `.jsonl` (last ~64 KB),
   off the main actor.
9. Memoize `ClaudeNativeSessions.exists()` per session id (invalidate on
   close) so reloads stop rescanning directories.

### P2 — polish
10. Mission Control previews: slice to the last ~22 lines *before*
    mapping; previews inherit the P0 frame cap.
11. Remove the unused shared transcript sink and its timer.
12. Debounce `saveStackChildren` on `recordVisit`.
13. `emitSample`: read a lightweight line tail instead of a full snapshot.
14. macOS 14: pin only when the content height ≤ viewport or drop the
    always-pinned fallback.

### Regression guard
`Tests/LoomTerminalTests/PerfProbes.swift` (suite "PERF PROBES") prints
the four key numbers; run it before/after each P0 change. Success criteria:
steady-stream frame cost < 3 ms on the session queue and < 1 ms of
AttributedString work per frame on the main thread.
