# Performance audit — 2026-09-22

Context: the goal is an app that feels instant — 60/120 fps terminal, no
main-thread stalls, instant echo and session switches, no beachballs with
many sessions, fast PR diffs. **This is a static audit**: the environment is
Linux, nothing was run or profiled. Every cost below is an estimate derived
from the code path cited and from the numbers measured on 2026-08-17
(M-series; ×2–4 on an older Mac). Re-measure with `PerfProbes` on a Mac
before and after each P0 change.

## Where the August plan stands

| # | Item | Status | Evidence |
|---|------|--------|----------|
| 1 | P0 frame cap | done | `SessionRuntime.swift:216-249`; Settings fps → `AppModel.swift:294-304` → `SessionManager.swift:192,232` |
| 2 | P0 incremental history tail | done | `SwiftTermEngine.swift:134-160`, test `SwiftTermEngineTests.swift:254-282` |
| 3 | P0 style-run AttributedString + row cache | partial | batching at `TerminalScreenView.swift:404-425`; **no per-row cache**, `attributed()` runs per row per body pass (`:389`) |
| 4 | P0 stable history-row identity | partial | `TerminalScreenView.swift:128-136`: ForEach still keyed by `\.offset`, absolute index only as `.id()` — see hot path 1 |
| 5 | P1 palette FTS debounce | done | `ActionPalette.swift:83-94`, detached query `AppModel.swift:1312-1317` |
| 6 | P1 reindex off main actor | done | `AppModel.swift:1284-1307` (`Task.detached`) — but see hot path 3 |
| 7 | P1 project tabs load in `.task` | partial | skills/rules `ContentView.swift:706-714`; Files still in body (`:780`); the `.task` scans run on the main actor |
| 8 | P1 FleetCard tail read | done | `MissionControlView.swift:135-145`, `ClaudeNativeSessions.swift:52-70` |
| 9 | P1 memoize `exists()` | done | `AppModel.swift:470-482`; the memo is cold at every launch — see hot path 2 |
| 10 | P2 preview slice before map | done | `MissionControlView.swift:165-172` |
| 11 | P2 remove shared transcript sink | missing | `AppModel.swift:398-399,405` still builds it; 250 ms timer at `FileTranscriptSink.swift:26-35` |
| 12 | P2 debounce `saveStackChildren` | done | `AppModel.swift:1930-1935` |
| 13 | P2 lightweight `emitSample` tail | missing | `SessionRuntime.swift:166-172,276` still `engine.snapshot()` |
| 14 | P2 macOS 14 pin fallback | done | fallback removed (64e00d8); `.defaultScrollAnchor(.bottom)` + gated `scrollTo` at `:171,185-191` |
| 15 | Regression guard `PerfProbes` | done | `Tests/LoomTerminalTests/PerfProbes.swift` — prints only, no `#expect`, no streaming variant, `existsScanCost` non-hermetic |

## Hot paths today

Ranked by estimated impact on the flows the user named.

### 1. Terminal rows get a new identity every frame; every visible row rebuilds its AttributedString — high
- Where: `Sources/LoomUI/TerminalScreenView.swift:128-136` (two positional
  `ForEach` + `.id(historyBase + index)` / `.id(lastRowID - …)`), `:388-425`
  (`row()` → `attributed()`).
- Mechanism (main thread, once per delivered frame, 30–120/s while streaming):
  `.id()` binds the row subtree to its value. Screen rows: `lastRowID` grows by
  k each frame that scrolls k lines, so all ~60 screen rows are torn down and
  recreated every frame from the first line of output. History rows: once the
  400-line tail is full, `historyBase` grows per frame and every visible
  history row is recreated too. Each recreated row is a CoreText layout of a
  ~200-col AttributedString (~100–300 µs) plus view-graph churn. Rows that do
  survive still run `attributed()` (one `AttributedString` per style run, two
  `DefaultTheme.terminalColor` lookups per run through the @Observable store)
  because nothing is `Equatable`. `.onChange(of: historyBase)` (`:185-191`) then
  calls `scrollTo` on a freshly created target each frame. The same body pass
  also runs on every drag-selection sample (`:278-279` write the pane's
  `@Binding` unconditionally) and, while the tail is filling, twice per frame
  (`ContentEndKey` → `@State contentEnd` at `:177` re-invalidates the view).
- Estimate: 6–20 ms of main-thread work per streaming frame at 200×60 — over
  budget at 60 fps, 20–50 % of the main thread at the default 30 fps; the
  spinner alone (1–2 rows at ~10 Hz) pays the full pass. This is the single
  reason 60/120 fps is not realistic today.

### 2. Cold start scans `~/.claude/projects` once per persisted session, on the main thread — high
- Where: `Sources/LoomApp/AppModel.swift:493-504` (`reloadPersistedSessions`,
  called from `start()` at `:455` inside `ContentView.onAppear`),
  `:477-482`, `Sources/LoomAgents/ClaudeNativeSessions.swift:20-36`.
- Mechanism: `nativeExistsCache` is empty at launch, so every
  interrupted/completed/failed/archived record calls `path(for:)`: one
  `contentsOfDirectory` of the root plus one per project directory until a
  hit; a miss walks all of them. Cost = records × (1 + P) listings before the
  first frame. Both inputs only grow (the session table is never pruned; a
  project dir appears for every cwd claude ever ran in). `resumeSession`
  (`:1725`) repeats one uncached scan; each close (`:1800`) and identity update
  (`:1832`) replays 1 + P listings on the main actor.
- Estimate: 0.34 ms/miss at 10 dirs (measured); 1–15 ms/record at 40–60 dirs
  with thousands of `.jsonl` → hundreds of ms to seconds of blank window on a
  long-lived install, growing weekly.

### 3. Startup FTS reindex serialises every store call behind one SQLite connection — high
- Where: `Sources/LoomApp/AppModel.swift:1296-1307` (`reindexAllSessions`),
  `:1270-1282` (`transcriptText`), `Sources/LoomPersistence/SessionStore.swift:13`
  (`DatabaseQueue`, default config), `:163-170` (`indexForSearch`: DELETE +
  INSERT of the whole transcript).
- Mechanism: the pass is detached (P1 done) but not incremental: every launch
  re-reads up to 2 MB per session (the cap is checked after appending a whole
  file, so a 10 MB rotated file is inserted whole) and re-tokenises it into
  FTS5, one write transaction + fsync each, for every record ever created.
  `DatabaseQueue` is one connection, reads included: while a write is in
  flight, `launchSession`'s `store.session(id:)` (`:1896`),
  `reloadPersistedSessions` (`:494,505`, ~12 call sites), `recordVisit`
  (`:1936`), the info popover's reads (`ContentView.swift:2522-2525`) and the
  `SessionManager` actor's `recordTransition`/`updateState`
  (`SessionManager.swift:274-279`) all block. The actor blocking is what makes
  `await manager.runtime(for:)` — a tab switch — wait too.
- Estimate: 50–300 ms per large transcript; hundreds of sessions → the queue
  is busy for tens of seconds after launch. "+" shows nothing, popovers hitch,
  switches lag during that window; repeated per session close (`:1811`).

### 4. Split diff: every materialised row is rebuilt per body pass, and scrolling triggers the pass — high (PR flow)
- Where: `Sources/LoomApp/SplitDiffView.swift:505-553` (rows inline in the
  `ForEach`), `:698-707` (`code()` builds two AttributedStrings per row per
  pass), `:448-453` + `Sources/LoomGit/DiffParser.swift:43-44`
  (`additions`/`deletions` = `hunks.flatMap` per header per pass), `:118-120`
  (`rowSpans` `@State` fed by the rows' own preferences),
  `Sources/LoomApp/GlobalPRsView.swift:815-818` (verdict binding mutates
  `model.prTabs`, read by `GlobalPRsView.body`).
- Mechanism: nothing between the `LazyVStack` and the `Text` is a value-only
  child view, and `SplitDiffView` carries closures, so any pass re-executes
  all 100–300 materialised rows ×2 sides: marker+text AttributedString,
  `threads()`/`draftComments()` filters over the whole comment array, a
  GeometryReader per row. The pass is triggered by: scrolling (new rows publish
  new `rowSpans` keys → `@State` write → full body → preferences re-emitted),
  each verdict keystroke, each drawer-resize drag sample (`drawerWidth`
  `@State` at 60–120 Hz), each session transition (`model.sessions` read at
  `GlobalPRsView.swift:30`), arrival of `highlights`.
- Estimate: 50–80 µs per row → 10–25 ms per pass on a large PR, i.e. dropped
  frames on every flick-scroll and every typed character in the summary.

### 5. PR sidebar: non-lazy list, search auto-expands whole orgs, a formatter per row, an NSScrollView per row — high (PR flow)
- Where: `GlobalPRsView.swift:138-151` (`ScrollView { VStack … }`), `:502`
  (auto-expand on non-empty query), `:908-925` (disabled horizontal
  `ScrollView` as a clip), `Sources/LoomApp/PRSidebarRows.swift:62-63`
  (`ISO8601DateFormatter()` per `age()` call), `PRCatalogModel.swift:82-86`
  (O(repos × projects) `caseInsensitiveCompare`).
- Mechanism: `query` is `@State` on `GlobalPRsView`, so each keystroke re-runs
  the entire sidebar; the first character unfolds every owner with a match and
  builds hundreds of `CatalogRepoRow`s eagerly (context menu, help, hover,
  two gestures each), each constructing one of Foundation's most expensive
  formatters. PR rows host a real `NSScrollView` each and hold closures, so
  none short-circuits.
- Estimate: tens to hundreds of ms on the first keystroke with a large org;
  a few ms per subsequent pass.

### 6. Session queue: full O(cols×rows) snapshot per frame, never gated; sampler adds two more per second; resize re-primes 1000 lines — medium
- Where: `Sources/LoomTerminal/SwiftTermEngine.swift:98-116` (`snapshot()`:
  one `getCharData` per cell, fresh arrays), `:23,33-40,195-198` (`dirtyRows`
  / `takeDirtyRows()` tracked but **no caller**), `SessionRuntime.swift:252-266`
  (`deliverFrame` never compares revision), `:166-172,270-279` (`emitSample`
  → `visibleTail()` → `snapshot()` every 500 ms per session, attached or not;
  `readiness()` at `:152-163` polled at 250 ms), `SwiftTermEngine.swift:145-151`
  (cold prime extracts `cap = 1000` lines when only 400 are ever read),
  `Sources/LoomTerminal/TerminalSurface.swift:112-114` (`receive` assigns
  `screen`/`history` even when unchanged).
- Mechanism: 2.2 ms measured at 100×40 → ~6 ms at 200×60 per frame, plus a
  snapshot per sample per live session (N × 2/s), plus 35–70 ms once after
  each settled resize or first attach of a long session — all on the serial
  queue that also carries `write()` (`:176-179`), so a keystroke typed during a
  burst waits behind it. Frames carrying no visible change (DSR replies, mode
  toggles) still cross to the main actor and invalidate every watcher.
- Estimate: ~40 % of a core per streaming session at 60 fps; 10 idle sessions
  waste ~5–15 % of a core; echo jitter of a few ms under load.

### 7. Default frame cap is 30 fps — medium
- Where: `AppModel.swift:294-299` (`preferredFrameInterval`, fallback 30),
  `SessionManager.swift:115`, `SessionRuntime.swift:220` (33 ms defaults),
  `SettingsPage.swift:11`.
- Mechanism: while claude streams, every frame — including the one carrying
  the user's echo — lands on the trailing edge, up to 33 ms late, and a
  ProMotion panel repaints text at 30 Hz. With items 1 and 6 fixed the
  per-frame cost leaves room for 60 on any supported Mac. (Verifiers agree on
  60 as default; one argued against deriving from `NSScreen`.)

### 8. PR tab switch re-parses, re-pairs and re-highlights the diff from scratch, with a fresh Highlightr — medium
- Where: `Sources/LoomApp/PRWorkspace.swift:140-146` (`.task(id:)` resets
  `diffFiles`/`highlights`), `:619-631` (three detached stages),
  `GlobalPRsView.swift:818` (`.id(key)` destroys the workspace),
  `Sources/LoomUI/DiffHighlighter.swift:47-50` (`Highlightr()` + theme per call).
- Mechanism: only gh strings are cached in `AppModel`; the derived products
  are view `@State`. Every tab activation, ⌘⇧[/], or Sessions→PRs round trip
  pays a JSContext + highlight.js load (~100–300 ms) plus seconds of CPU on a
  5k-line PR, showing "Loading the diff…" then a plain→coloured flip.

### 9. Session switch: spinner flash and an actor round trip before the last screen paints — medium
- Where: `Sources/LoomApp/TerminalPane.swift:141-149`, `AppModel.swift:2023-2025`,
  `ContentView.swift:1799-1802` (`.id(sessionID)`).
- Mechanism: the pane is recreated per switch, `@State surface` starts nil,
  the first commit shows `ProgressView()`, then `.task(id:)` hops to the
  `SessionManager` actor and back before the retained screen can render; the
  attach then produces a second full render. The hop queues behind whatever
  the actor is doing (store writes per transition, hot path 3; a fan-out
  launch's `forkpty`). The `TerminalSurface` already exists and is idempotent
  (`SessionRuntime.surface()`), so the async fetch is avoidable. Note
  `TerminalPane.swift:141` `.task { await surface.attached() }` has no id: a
  pane reused with a swapped surface (PR drawer, `GlobalPRsView.swift:844`)
  would never re-attach.

### 10. Mission Control: every visible card streams at the pane frame rate — medium
- Where: `Sources/LoomApp/MissionControlView.swift:154` (`attached()`),
  `:165-181` (`lines` recomputed + 22 positional `Text`s per frame).
- Mechanism: attachment is binary; N working cards = N snapshots/interval on
  N queues + N main-actor hops + N SwiftUI passes of 22 rows, at 30–120/s, for
  7 pt text nobody can read above ~5 fps. 10 cards at 30 fps ≈ 300 main-actor
  updates/s (10–15 % of the main thread), double at 60.

### 11. Launch does WKWebView creation and four JSON decodes before the first frame — medium
- Where: `AppModel.swift:1496-1500` (`restoreStackChildren` → `openTab` per
  URL), `Sources/LoomWeb/BrowserController.swift:32-37,76-95` (each `openTab`
  reconciles → allocates a `WKWebView`, loads it at `:92`, then loads it
  **again** at `:36`; tabs beyond the 4-tab LRU are created then evicted in
  the same loop), `AppModel.swift:388-391` (PR list cache, drafts, catalog,
  tabs decoded synchronously). One verifier rated the JSON part immaterial;
  the WebKit part (process spawns + network loads for hidden panes, competing
  with claude boots and the reindex) is agreed medium.

### 12. Sidebar re-renders wholesale on every state transition; `dormantSessions` recomputed ~6× per pass — medium
- Where: `ContentView.swift:2028-2043` (`stackItems` per project group reads
  `model.dormantSessions`), `AppModel.swift` `dormantSessions` (O(records ×
  live) filter, computed), `:1817` (one mutation per real transition).
- Mechanism: transitions are already deduped on the actor (not per 500 ms
  sample), but each one invalidates SessionsView, SessionDetailView's
  breadcrumb and ProjectsView; cards carry closures so ~25 bodies re-run.
  ~3–4 ms per transition on M-series, stolen from terminal frames.

## Secondary findings

- `recordVisit` does a synchronous SQLite write on the main actor per page
  load (`AppModel.swift:1936`); waits behind hot path 3. Low.
- Session info popover runs three store reads in `body`, one fetching the
  whole transition journal to take `.last` (`ContentView.swift:2522-2525`). Low.
- Files tab lists the directory (a stat per entry) in `body` on every
  ProjectsView render (`ContentView.swift:780`); skills/rules `.task` scans
  are main-actor-isolated (`:706-714`). Low.
- Goal-field keystrokes re-render all of ProjectsView; `RecentSessionRow`
  allocates a `RelativeDateTimeFormatter` per row (`ContentView.swift:1764`). Low.
- Document viewer re-parses Markdown over up to 200 KB on every ProjectsView
  pass (`ContentView.swift:872-926`). Low–medium while sessions run.
- ⌘K: fuzzy ranking (ICU folding per candidate, hundreds incl. history) runs
  2–3× per body and the body re-runs per hover row (`ActionPalette.swift:36-68`). Low–medium.
- Filter change refreshes expanded projects serially, one `gh` process at a
  time (`PRFilters.swift:57-59,259-261`). Medium felt latency, main thread idle.
- ThemePreview rebuilds the 16-colour palette ~60× per render and a card hover
  re-renders the whole Settings page (`ThemePreview.swift:15`, `SettingsPage.swift:383`). Low.
- `UsageIndex.refresh` does one read + one write transaction per `.jsonl`
  (`UsageIndex.swift:46-67`), holding the shared queue in thousands of hops. Low.
- Hook payload framing rescans/recopies the buffer per 4 KB event and parses
  each hook three times (`HookSocketServer.swift:129-143`). Low, IPC queue only.
- Shared `FileTranscriptSink` + 250 ms timer still created (P2 #11). Low.
- Disputed on impact (one verifier low, one negligible), listed for
  completeness: keystrokes hop onto the session queue behind parse/snapshot
  work (`SessionRuntime.swift:176-179`) — real, but ≤1 ms once item 6 lands;
  link detection re-scans the paragraph per mouse move
  (`TerminalScreenView.swift:157-168`) — sub-millisecond; `forkpty` + `store.insert`
  on the `SessionManager` actor (`SessionManager.swift:186-206`) — tens of ms,
  visible only during fan-out.

## What is already good

Frame cap with immediate leading edge; incremental history tail (14.7 ms →
~0, buffer-identity equality on unchanged lines); style-run batching;
transcript sink fully off the hot queues; `modes`/`hasOutput` assigned on
change; hover writes state on change only; resize debounced 220 ms and
deduplicated in the runtime; transitions deduped on the actor so samples never
reach the UI; FTS search, reindex, FleetCard tail reads, PR parse/pair/
highlight, git/gh processes all off the main actor; PR caches with TTL and
debounced persistence; `MarkdownBlockView` caches; `ThemeStore.apply` compares
before assigning; no per-cell `Text`; no global event monitors; bounded
`AsyncStream` buffers.

## Action plan

### P0 — makes 60/120 fps real
1. **One `ForEach` keyed by the absolute row number + an `Equatable` row view**
   (`TerminalScreenView.swift:128-136,388-425`): `Row(id:line:cursorCol:)`,
   drop `.id()`, `TerminalRow: View, Equatable` with `.equatable()`, move
   `attributed()` in as a static, hoist `boldFont` and the default foreground
   out of the run loop. Keep `lastRowID`, `.defaultScrollAnchor(.bottom)` and
   the `onChange(of: historyBase)` re-pin. Also: keep `contentEnd`/`viewportHeight`
   in a non-observed reference box read only by that `onChange`, and in the
   drag `onChanged` assign `selection` only on change. **M.**
2. **Index native sessions once per reload** (`ClaudeNativeSessions.index()`
   → `Set` of lowercased `.jsonl` names, one walk of 1 + P listings; seed
   `nativeExistsCache` for every uncached record in `reloadPersistedSessions`;
   `resumeSession` reads the memo). Keep the launch reload synchronous so
   `restoreLastSession` still sees its record. **S.**
3. **Incremental FTS index + readers off the writer**: v10 migration
   `sessionIndex(sessionID, bytes, modifiedAt)`; stat the transcript dir and
   skip unchanged sessions; delete by stored rowid; cap `transcriptText` by
   bytes read, not after appending a file. Switch `SessionStore.database`
   (and `UsageIndex`) to `DatabasePool` typed `any DatabaseWriter` (WAL: reads
   never wait on writes); move `recordVisit`'s write to `Task.detached`. **M.**
4. **Diff rows as value views** (`SplitDiffView.swift`): `DiffRowView: View,
   Equatable` with `.equatable()` (row, pre-looked-up highlight strings,
   isSelected, unified); `additions`/`deletions` stored `let`s in
   `DiffParser.File`; index comments/drafts once per change; keep `rowSpans`
   and `diffSize` in a non-observed box with a small `barAnchorY` `@State`
   refreshed only when the anchor moves. **M.**

### P1 — fluidity under load and in the PR tab
5. Gate frame delivery: remember `(revision, cursor, modes, hasOutput)` in
   `deliverFrame`, return early when unchanged unless forced (attach/resize);
   in `TerminalSurface.receive` skip identical `screen`/`history`. Then
   incremental `snapshot()`: reuse `lastLines` for rows not in
   `takeDirtyRows()`, extract a row via one `getLine(row:)`. **S + M.**
6. `emitSample`/`readiness()`: memoize the 12-line tail on
   `(bytesReceived, appliedGeometry)`; add `TerminalEngine.visibleTail(limit:)`
   walking rows bottom-up via `getLine(row:).translateToString` (default
   extension via `snapshot()` keeps `LineEngine` compiling). Do not skip
   samples — hysteresis needs them. Prime the tail cache with `limit` when
   empty, keep 1000 only as the growth bound. **S.**
7. Default 60 fps at all four sites (`AppModel.swift:297`, `SessionManager.swift:115`,
   `SessionRuntime.swift:220`, `SettingsPage.swift:11`); reword the help text
   (30 = battery/older Mac, 120 = ProMotion opt-in). **S.**
8. PR sidebar: `LazyVStack` with `Section` per owner/project so rows are
   direct lazy children; cap auto-expansion at 20 repos with a "N more" row;
   `private static let iso = ISO8601DateFormatter()`; replace the disabled
   `ScrollView` with a `Layout`/`fixedSize + frame(minWidth: 0) + clipped`;
   `PRSidebarRow: Equatable` + `.equatable()`; tokenize the query once per
   pass and use a lowercased `Set` of project repo names. **S–M.**
9. Cache diff products in `AppModel` (`[prKey#sha#scheme: (rows, highlights)]`,
   evicted with `prDiffCache`) behind an `actor DiffPipeline` holding one
   `Highlightr` per colour scheme and an in-flight map; seed
   `PRWorkspaceView`'s `@State` from the cache in `init`. Cache `prTour`. **M.**
10. Surface cache on `AppModel` filled after `manager.launch/resume`
    (`surfaceCache[id] = runtime.surface()`), dropped on archive;
    `TerminalPane.init` seeds `_surface` from it; `.task(id: ObjectIdentifier(surface))`
    for the attach; blank background instead of `ProgressView` on a miss.
    Keep `.id(sessionID)` (per-session `@State` must reset). Same seeding in
    `FleetCard`. **S.**
11. Preview cadence: `setAttachment(_:attached:cadence:)` with
    `.live`/`.preview(250 ms)`; `scheduleFrame` uses `frameInterval` only when
    a live watcher exists; Mission Control attaches `.preview`. **S.**
12. Lazy browser restore: `BrowserController.restoreTabs(urls:)` (model only)
    + `materialize()` from `BrowserPanelView.onAppear`; delete the duplicate
    `load` at `BrowserController.swift:36`. Decode `pr-cache-v2.json` and
    `repo-catalog.json` on a detached task, merging by `fetchedAt`, awaited by
    `ensurePRs`/`refreshPRs`/`savePRListCache`. **S.**
13. Sidebar: read `dormantSessions` once per render and group in one pass;
    memoize it on `(session ids + nativeIDs, reload generation)` with
    `@ObservationIgnored`; `SidebarSessionCard: Equatable` on
    `(item, childCount, isSelected)` + `.equatable()`. **S–M.**

### P2 — polish
14. Info popover: `SessionStore.lastTransitionDate` (`ORDER BY at DESC LIMIT 1`),
    one detached snapshot into `@State` via `.task(id:)` on the panel. **S.**
15. Files tab into `@State` via the existing `.task(id:)` (add `filesPath` to
    the key); make `listFiles`/`ruleFiles`/`skills` `nonisolated static` and
    call them from `Task.detached`; `LazyVStack` for the rows. **S.**
16. `GoalFieldView` owning `goal` `@State`; static `RelativeDateTimeFormatter`. **S.**
17. Parse the document once in `openDocument` (store the `AttributedString`). **S.**
18. ⌘K: `searchKey: [Character]` precomputed per `PaletteAction`, rank by
    index, compute sections once per body (`@State` recomputed in
    `.onChange(of: query)` / actions ids); hover writes on change only. **S.**
19. `PRFilters`: `withTaskGroup` over `ensurePRs`; coalesce `savePRListCache`
    like `savePRTabs`. **S.**
20. `ThemePreview`: build the palette once per body into a closure-free
    `MockWindow(palette:)`; theme grid + preview in a child owning `hoveredFamily`. **S.**
21. `UsageIndex.refresh`: load the `usageFile` table once, skip unchanged files
    without DB access, flush in batches of ~64 files. **S.**
22. `HookSocketServer`: scan from the appended offset, `removeSubrange` instead
    of `Data(buffer)`; parse the payload once on the actor. **S.**
23. Drop the shared `FileTranscriptSink` (make `Dependencies.transcript`
    optional). **S.**

## Regression guard

Extend `Tests/LoomTerminalTests/PerfProbes.swift` and make it assert, not
just print (generous thresholds, ~3× target, so debug builds pass):
- `frameCost` streaming variant: feed one line between `historyTail(400)`
  calls; expect < 1 ms/frame. After P1-5, add `snapshotDirtyCost`: a one-row
  change followed by `snapshot()`; expect < 0.5 ms and equality with a
  from-scratch snapshot after scroll, IL/DL, alt-buffer switch and resize.
- `frameGate`: a `SessionRuntimeTests` case feeding bytes that change no
  visible cell and asserting no `receive` on the surface; and a `.preview`
  watcher receiving at most one frame per 250 ms while a burst streams.
- `tailPrimeCost`: resize then `historyTail(400)` on 5,000 lines; expect the
  count of extracted rows == 400 and equality with a fresh engine.
- `visibleTailCost`: `visibleTail(12)` vs `snapshot()`-derived default on a
  screen with trailing blanks, NULs and a wide character; expect equality
  and < 0.3 ms.
- `attributedCost`: build rows with 8 coloured runs and bold pieces (the
  current probe measures plain appends only); expect < 1 ms for 40 rows.
- `existsIndexCost`: `ClaudeNativeSessions.index()` over a temp tree of 50
  dirs × 200 files; expect < 20 ms and O(1) membership per record
  (hermetic — replace the probe that hits the real `~/.claude/projects`).
- New `LoomPersistenceTests` case: `reindexAllSessions` on an unchanged
  transcript directory performs zero `indexForSearch` writes (count via a
  `sessionIndex` row check).
- New `LoomAppTests`/UI-free check for the diff: `DiffFileRows.compute` on a
  5k-line PR followed by 100 `DiffRowView ==` comparisons < 1 ms.

Success criteria (M-series, release build): steady-stream frame < 1 ms on the
session queue and < 1 ms of main-thread row work when k ≤ 3 lines scroll; a
session switch paints the retained screen in the first commit; cold launch
before first frame < 100 ms independent of session count; the diff scroll
never re-runs `SplitDiffView.body`; a PR tab revisit paints coloured in its
first frame.
## Implementation status — 2026-09-23

Applied on this branch, one commit per item (`git log aad37d7..HEAD`):

| Item | Commit(s) |
|------|-----------|
| P0-1 terminal rows: absolute identity, `TerminalRow: Equatable` | `7f29267` |
| P0-2 native conversations indexed in one walk | `019e0e0`, `d0d0b04` |
| P0-3 WAL pool on disk, fingerprinted incremental reindex | `150b1b6`, `d0d0b04` |
| P0-4 split diff: value rows, indexed threads, geometry off state | `8b7e19f` |
| P1-5 frame gate + incremental snapshot, memoized `visibleTail` | `651fe7c`, `42f8e79` |
| P1-6 60 fps default | `504bd24` |
| P1-7 PR sidebar: lazy stack, capped unfold, comparable rows, one formatter | `56c3136` |
| P1-8 chips: `ScrollView` per row **not replaced** (hover/scroll semantics untested here) | — |
| P1-9 diff parsed/paired/coloured once, cached per PR and scheme | `2387e8e`, `7bf8e01` |
| P1-10 session switch from the cached surface | `2cb4d07`, `dd86dc4`, `1a08037` |
| P1-11 preview cadence for Mission Control | `d469c9e`, `0c50cbb` |
| P1-12 restored browser tabs stay model-only until shown (JSON decode off main: **not done**) | `076ea3d` |
| P1-13 sidebar: dormant read once, comparable cards | `caf8f23` |
| P2-14 session info reads off main, once per open/transition | `822bc80`, `5d1a9d0` |
| P2-15 files/skills listings off main, cancellation-safe | `c79a9bd`, `ebe7f94` |
| P2-16 `GoalFieldView` extraction: **not done** | — |
| P2-17 palette sections computed on change | `ec9f015`, `be10e7f` |
| P2-18 PR filters refresh together, list cache saved once | `043ccd9` |
| P2-19 theme preview palette memo | `a70e364`, `cf99b85` |
| P2-20 Settings theme gallery child view: **not done** | — |
| P2-21 usage index: table read once, batched writes | `2c08e43`, `ae2ad10` |
| P2-22 hook socket lines cut in place, scan resumes | `575ab34`, `65d4c40` |
| P2-23 shared transcript sink removed | `4814336` |

Two adversarial reviews (P0 batch, then P1/P2 batch) ran over the commits;
their confirmed findings are the fix commits listed above. The regression
guard probes in this document are still to be written. Nothing here was
compiled: build and run `swift test` on a Mac before merging.
