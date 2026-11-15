# Performance audit — 2026-11-15

Context: two requests. ⌘K must answer in the keystroke and start a review
from a pull request's URL; the PRs tab must perform better, above all when a
review is started. Scope: the PRs tab (`GlobalPRsView`, Browse and Review),
the review launch (`startPRReview` → `launchPRReviewSession`) and the ⌘K
palette. **This is a static audit**: the environment is Linux with no Swift
toolchain, so nothing was compiled, run or profiled. Every cost below comes
from the code path cited; where a number appears it is an estimate, and
says so. File and line references in "What was found" are those of `main`
at `9973bce`, before the changes; those in "What was changed" are the
working tree's.

## Where the September plan stands, in this scope

| # | Item | Status | Evidence |
|---|------|--------|----------|
| P0-4 | Diff rows as value views | done, but still compared on every pass | `SplitDiffView.swift:719,804`; the pass itself was never made rarer — hot path 2 |
| P1-7, P1-8 | PR sidebar: lazy, capped, comparable rows | superseded | the sidebar is gone; Browse (`cb654a9`, 2026-11-05) replaced it with a `Table` and was never audited — hot path 7 |
| P1-9 | Diff parsed, paired and coloured once, cached per PR | done, and undone by every list fetch | `DiffPipeline.swift`, `AppModel.cachedDiff`; `refreshPRs` dropped the whole project — hot path 5 |
| hot path 4, other triggers | verdict keystrokes, drawer drag, session transitions re-run the diff | listed, not fixed | only the rows were made comparable — hot paths 2, 6, 9 |
| P2-17 | Palette sections computed on change | done, half of it | titles were still folded through ICU on every keystroke — hot path 11 |
| P2-18 | Filters refresh the projects together | done | `PRFilters.swift:57,256` → `ensurePRs(for:)` |

## What was found

Ranked by what the user feels in the two flows named.

### 1. A review's drawer waits for the network — high
- Where: `Sources/LoomApp/PRModes.swift:125-135` (`startPRReview`),
  `Sources/LoomApp/AppModel.swift:1320-1390` (`launchPRReviewSession`),
  `:1424-1455` (`syncReviewWorktree`), `Sources/LoomApp/GlobalPRsView.swift:38`
  (the drawer renders only when a session exists), `:438-447` (quick actions).
- Mechanism: the drawer opened only after `launchPRReviewSession` returned.
  Fresh review: `git fetch origin pull/N/head`, `git worktree add`, rev-parse
  and five `git config` processes in series, then the command file, then
  `forkpty`. Reattach — a session that is already live — still awaited a
  non-quiet `syncReviewWorktree` (the same fetch plus about seven local git
  processes) before the drawer showed a terminal that existed all along. A
  diff quick action waited further: sync, `awaitReviewSetup`, then
  `submitWhenReady`'s 250 ms polls.
- What the user saw: the tab at once, then only the toolbar's small
  "Preparing the review worktree…" for the whole checkout.
- Shown by the code; the duration is the network's and the repository's.

### 2. `GlobalPRsView.body` re-ran on every session transition, and the diff with it — high
- Where: `GlobalPRsView.swift:33, 398, 485, 500, 533` (`model.sessions`),
  `:25` (`prTabs`), `:289, 329, 332` (`prReviewLaunching`, `prRefreshing`),
  `:167` (`workflows.runs`), `:513` (`agentBrowsers`), `:431-466` (the
  workspace built with fresh closures), `AppModel.swift:1203-1211`
  (`reviewSession(forPR:)` scans `sessions` and `allRecords`, and wrote
  `prSessionMap` lazily during a body pass), `:2557` (one write per transition).
- Mechanism: one observed array, mutated per transition of any session, read
  by the parent of the workspace. Closure properties make `PRWorkspaceView`
  incomparable, so each pass re-ran its body and `SplitDiffView.body`
  (`SplitDiffView.swift:231`): every hunk of every materialised file rebuilds
  `Array(rows.enumerated())` (`:711`) and constructs and compares each
  `DiffRowView`. A review start is five to eight such passes in a row
  (launching set, session appended, records reloaded, state transitions),
  on the main actor, while the drawer's terminal paints.
- The size of one pass is not measured; September put it at 10–25 ms on a
  large PR before the rows were comparable.

### 3. `PRWorkspaceView.load` fetched in series — high
- Where: `Sources/LoomApp/PRWorkspace.swift:654-678`.
- Mechanism: `prDetail`, then `reviewComments`, then `prDiff` — three `gh`
  processes one after the other — then parse and pair, then highlight, then
  `fileViews` (paginated GraphQL). The diff, which is what the Files region
  shows, was asked for third. No `Task.isCancelled` check anywhere, and `gh`
  cannot be cancelled (`GitHubService.swift:1024-1060`).
- Time to the first diff: the sum of three round trips instead of the
  slowest, with "Loading the diff…" on screen. Runs on every tab opened, on
  every review started from Browse, on refresh and after each posted comment.

### 4. The poll restarted that load, and nothing was shared — high
- Where: `GlobalPRsView.swift:99, 140-146` (`watchActivePR`),
  `AppModel.swift:1509-1540` (`refreshOpenPR`), `PRWorkspace.swift:170`
  (`.task(id:)` keyed on head and update stamp), `PRListCache.swift:11`
  (rows can be 3 h old).
- Mechanism: a tab opens on a list row up to three hours old; the poll's
  `gh pr view` finds it moved, drops the PR's caches and rewrites the tab's
  row, which restarts the workspace's task mid-load. The restarted load
  missed caches the first had not filled yet and spawned every call again;
  the cancelled one kept running to the end. For a PR opened by URL the poll
  repeated the `gh pr view` made a moment before.
- Likely on any PR with activity since the list was fetched, not certain.

### 5. A list fetch threw the whole project away — high
- Where: `AppModel.swift:1162-1180` (`refreshPRs`).
- Mechanism: every cached detail, raw diff, parsed rows, highlights, guided
  tour, comments and viewed state of the project, dropped by prefix on any
  list fetch — Browse refresh, a filter change, the 3 h TTL on a scope visit,
  `consumePendingPR`, a PR opened by URL. Each open tab of the project then
  reloaded from scratch on its next visit, head moved or not: four `gh`
  calls, a re-parse, a highlight.js run, and a tour that had cost an agent
  run. It undid P1-9 wholesale, and could land in the middle of the load a
  review start had just begun.

### 6. The verdict bar wrote the tabs at every keystroke — medium
- Where: `PRWorkspace.swift:577`, `GlobalPRsView.swift:461-463`,
  `Sources/LoomApp/PRCatalogModel.swift:313-325`.
- Mechanism: `prTabs` is one observed struct, read by `GlobalPRsView`
  (`:25`), `PRTabStrip` (`PRTabStrip.swift:17`), `PRModeSwitch`
  (`PRBrowserView.swift:675`) and the verdict bar itself. Each character
  re-ran the toolbar, the strip, the workspace and `SplitDiffView.body`
  (September's hot path 4, second trigger).

### 7. Browse built, filtered and sorted its rows three times a pass — medium
- Where: `Sources/LoomApp/PRBrowserView.swift:342-346` (`rows`), read at
  `:224` (caption), `:255` and `:351` (selection actions), `:355` (table);
  `:485-490` (`repoRows`, twice); `PRModes.swift:48-78`.
- Mechanism: each evaluation rebuilds every row (two UUID-string keys each),
  tokenises the query once per row even when it is empty
  (`PRSidebarFilter.swift:31-36`) and sorts with a `KeyPathComparator` on a
  `String` key path — a localised comparison per pair. The body runs per
  filter keystroke, per row click, per sort click, per list arrival, and per
  session transition (`reviewSessionRank` reads `sessions`).
- The magnitude is a guess: a few ms for 300 pull requests, times three;
  much more over a catalog of thousands of repositories.

### 8. A revisited tab painted, then filled in three more steps — medium
- Where: `PRWorkspace.swift:137-155` (the init seeded only the rows, the
  colours and the tour), `:656-658, 665-672, 675-677`.
- Mechanism: detail, line comments, viewed files and the draft started
  empty and were assigned by `load` in three steps, every value a cache hit.
  Threads were inserted under their lines after the first frame, then the
  viewed files folded (`SplitDiffView.swift:280`): the layout jumped twice.
  On every tab switch (`.id(key)`) and every return to the PRs tab.

### 9. Dragging the drawer re-ran the workspace per sample — medium
- Where: `GlobalPRsView.swift:50, 378-386` (`drawerWidth` `@State`), `:219,
  435` (`controlsInset` into the workspace), `PRWorkspace.swift:450, 604`
  (the only two readers).
- September's hot path 4, third trigger; only the rows were fixed then.

### 10. Every launch reloaded the records and re-assigned everything — medium
- Where: `AppModel.swift:630-666` (`reloadPersistedSessions`), called at
  `:1388, 2439, 2549, 2609`.
- Mechanism: the whole session table and the projects read from SQLite on
  the main actor, then `allRecords`, `interruptedSessions`, `historySessions`,
  `projects` (twice, `:646` and `:1965`) and `prTabs` written, changed or
  not — each write waking every reader, in the frames the drawer slides in.

### 11. ⌘K was a sheet, and folded every title at every keystroke — high (palette)
- Where: `Sources/LoomApp/ContentView.swift:300` (`.sheet`), `:523` (a
  hard-coded 0.3 s before a second sheet), `:482-655` (`paletteActions`),
  `Sources/LoomApp/ActionPalette.swift:46-56, 65, 97-109, 139-148, 206`,
  `Sources/LoomUI/CommandPalette.swift:58-60`.
- Mechanism: a window built and a system transition played on every open and
  every close; a follow-up question was a second sheet behind a fixed wait.
  Per keystroke: two to four body passes (the list trailed the text by one),
  every title normalised again through ICU — live and dormant sessions
  included, an unbounded count — a title-keyed dictionary, a sort. Rows were
  identified by position, so a changed filter recreated them; a hover wrote
  the palette-wide selection and scrolled.
- Estimates, none measured: 200–300 ms each way for the sheet; a few ms per
  keystroke at hundreds of entries.

### 12. A review from a URL took two round trips and a click between them — medium
- Where: `PRBrowserView.swift:313-315`, `PRCatalogModel.swift:168-201`.
- Mechanism: `gh pr view -R` with no loading state, then the tab; the review
  needed a second click, and only then did `git fetch` start.

## Secondary findings

- Around every checkout, five `git config` processes in series
  (`extensions.worktreeConfig` set twice, `config --global --get
  core.excludesFile` asked each time): `GitHubService.swift:935-954,
  986-1002`. Roughly 10 ms a process — an estimate.
- `syncPRWorktree` fetched into the repository's shared `FETCH_HEAD` and made
  the worktree from it (`GitHubService.swift:878-879`): two reviews of one
  repository started together could check out each other's head. A
  correctness finding met on the way; it matters more once reviews start
  from the palette.
- `launchPRReviewSession` had no guard of its own against two callers
  (`startPRReview` checked, `sendToPRReviewSession` and a scheduled review
  did not): one worktree, two sessions.
- `ClaudeStatusLine.user(cwd:)` read and parsed up to three settings files on
  the main actor between the launch's awaits (`AppModel.swift:1357-1360`).
  A guess as to size: small.
- `project(forRepo:)` answers nil until every project's remote has been read
  (`PRCatalogModel.swift:15-28`): just after launch, a repository that is a
  project was offered for cloning.

## What is already good

`gh` and `git` processes, JSON parsing, the diff parse and highlight.js all
run off the main actor; diff rows are values (`DiffRowView`); diff products
are cached per PR and colour scheme behind `DiffPipeline` with an in-flight
map; the tabs and the PR lists are saved debounced, in order; the drawer
slides in at full width and `TerminalPane` keeps `.id(sessionID)`, so the
terminal is never resized by an animation; the minute poll is throttled to
20 s per PR; the palette's transcript search was already debounced and off
the main actor.

## What was changed

### Review launch (model)
1. **The drawer first.** `startPRReview` opens the tab's drawer before any
   work and marks the PR launching in the same call (`PRModes.swift:125`,
   `AppModel.reviewLaunchTask`, `:1521`); the drawer closes again if no
   session came of it. Reattach, sync and command install still run, behind
   the drawer.
2. **One launch per PR.** `singleReviewLaunch` (`AppModel.swift:1534`): a
   second caller — a click, the URL prompt, a quick action, a scheduled
   review — joins the launch that runs.
3. **A review from a reference.** `startPRReview(reference:)`
   (`PRModes.swift:156`): a row an open tab or a loaded list already holds
   is a plain "Start review"; otherwise `gh pr view` and the checkout run
   together (`launchReview`, `AppModel.swift:1681`), the tab and its drawer
   open when the row lands, claude starts when both are there. A repository
   that is no project goes through the clone dialog and carries the intent
   with it (`PendingClone.startsReview`). `resolvedProject(forRepo:)` waits
   for the remotes before concluding there is no project.
4. **One `gh` call per PR and kind at a time.** `prDetail`, `prDiff`,
   `reviewComments` and `fileViews` keep the call in flight and let a second
   caller join it (`AppModel.swift:722, 747, 811, 855`); a row just fetched
   is stamped so the poll does not ask for it again (`notePRRowFetched`).
5. **Eviction per PR.** `refreshPRs` drops only the PRs whose head or update
   stamp moved, and the ones gone from the list
   (`GitHubService.staleContent`, `GitHubService.swift:626`;
   `evictStaleContent`, `AppModel.swift:1342`). The diff pipeline forgets
   a PR by its exact key (`DiffPipeline.evict(key:)`): a prefix match on
   `…#12` would take `#123` with it. A row written into a tab from outside
   the poll and the lists — a click, a pasted URL, a scheduled review —
   drops what was loaded for another one first (`dropPRContentIfMoved`):
   the tab's row is the row its content was loaded for, which the eviction
   and the poll both rely on.
6. **Writes on change.** `reloadPersistedSessions` compares before assigning
   and writes `projects` once, already ordered (`AppModel.swift:660`);
   `prTabs` is rewritten only when a tab goes.
7. **"Is it live" without `sessions`.** `liveSessionIDs`, written when a
   session appears or goes; `reviewSession(forPR:)` and
   `liveReviewSession(forPR:in:)` read it and a set of record ids
   (`AppModel.swift:200, 1390, 1401`); `prSessionMap` is read once, at init.
8. **Checkout.** New worktrees are made one at a time per repository
   (`SerialTurns`), the `git config` writes are remembered per run
   (`WorktreeConfigMemo`), the status line is read off the main actor.

### PRs tab (views)
9. **`PRWorkspaceView.load` fetches together and shows each piece as it
   lands** (`PRWorkspace.swift:637`): detail, comments, diff and viewed files
   leave in one task group; the rows are parsed as soon as the diff is there,
   the colours follow, the recap waits for the rows and the boxes. A run its
   task dropped writes nothing more; the run that replaced it joins the calls
   still in flight (item 4).
10. **The first frame is seeded** (`PRWorkspace.swift:153`): detail, line
    comments, viewed files and draft from the model's caches, which are no
    longer observed, beside the rows, colours and tour. A revisit paints once.
11. **The drawer is a view of its own** — `PRSessionDrawer`
    (`GlobalPRsView.swift:517`): handle, header, resize edge, width and
    `TerminalPane`. While the PR is launching and no session runs yet it
    shows a spinner and "Preparing the review worktree…" in the frame the
    terminal will take: the session arriving changes no width.
12. **`GlobalPRsView.body` reads no session state.** The toolbar's actions
    (`PRReviewToolbarActions`, `:362`), the drawer's title and status
    (`ReviewSessionTitle`), the browser mark and the review tabs read what
    they show themselves; `SessionStateDot` (`PRTabStrip.swift:44`) is the
    dot of the tab strip, of the drawer's handle and of the review tabs. A
    transition repaints a dot.
13. **The workspace is compared, not rebuilt.** `PRWorkspaceView: Equatable`
    on the project, the row, the region and whether the drawer shows a live
    session (`PRWorkspace.swift:108`), under `.equatable()`
    (`GlobalPRsView.swift:269`). Its two closures read nothing of the pass
    that built them.
14. **The drawer's width is a shared reference** — `PRDrawerLayout`
    (`GlobalPRsView.swift:291`), read by the drawer and by the two bars that
    step aside for it (`PRDrawerClearance` around the files header, the
    verdict bar). A drag re-runs those three.
15. **The verdict bar owns its text** — `PRVerdictBar`
    (`PRWorkspace.swift:832`): written to the tab 300 ms after the last
    keystroke, when a verdict is sent and when the bar leaves the screen. It
    follows the tab's summary until something is typed, and again once its
    own write came back or the summary was emptied by a sent review; a
    scheduled review's summary never overwrites keystrokes not yet written.
16. **Browse computes its rows once per pass, and filters and sorts once per
    change** (`PRBrowserView.swift:39, 359, 515`): the caption, the
    selection's actions and the table are handed one array; a memo keyed on
    the scope's rows, the text and the sort order skips the filter and the
    sort when none of them changed, and the filter altogether when no text is
    typed.
17. **A review asked for by reference shows while its PR is fetched**:
    `PRReviewsOpening` in the tab strip and in Browse's toolbar, and in
    Review's empty state.

### Palette
18. **An overlay of the window, not a sheet** (ADR-0024): `PaletteOverlay`
    (`ActionPalette.swift:174`), no transition either way; the terminals
    stand down under it (`WindowOverlay`, `KeyInput.swift:491`) and the
    keyboard goes back to what had it (`PaletteKeyboard`).
19. **One keystroke, one pass**: titles folded once per action list
    (`CommandPalette.key(for:)`), ranked by index (`rankIndices(query:keys:)`,
    `CommandPalette.swift:45, 52`); text, sections and selection change
    together (`edit`, `ActionPalette.swift:370`); rows are compared values
    identified by their action (`PaletteRow`, `:624`); the list scrolls from
    the keyboard only.
20. **An action can ask its question in the palette**: `PalettePrompt`;
    "Review code" asks for the pull request (`ContentView.swift:676`), shows
    the PRs tab, closes the palette and calls `startPRReview(reference:)`.

## What was NOT measured

Everything: nothing here was run on a Mac. No build, no test run, no
Instruments trace — the code above was written against the declarations it
calls and has not been compiled, and no figure in this document is a
measurement. On a Mac, before merging:

1. `swift build`, then `swift test`. The constructs least sure to compile:
   in the model, the `didSet` on the observed `sessions`, the generic
   `SerialTurns.run`, the tuple-valued in-flight dictionaries and the
   `@escaping @MainActor () async -> SessionID?` parameter; in the views,
   the task group of `PRWorkspaceView.load` (it writes view state and adds
   tasks while it drains), `PRWorkspaceView: Equatable` with its own `==`,
   and the generic `PRDrawerClearance` around the files header.
2. The probes that exist: `PerfProbes` (LoomTerminalTests — streaming frame,
   one-row snapshot, tail re-prime, visible tail, native index),
   `TerminalRowProbes` (LoomUITests — forty coloured rows),
   `DiffRowsProbes` (LoomGitTests — a 5,000-line parse and the row
   comparisons). They guard September's work and should still pass; **none
   of them covers anything in this audit.**
3. New tests, not probes: `PRStaleContentTests` (which PRs a refetched list
   makes stale), the `ReviewWorktreeTests` additions (two reviews started
   together keep their own heads; a reused or recreated worktree is
   configured again), `CommandPaletteTests` (the folded keys rank as the
   titles did). They assert behaviour, not time.

What to measure first, in this order:

1. **Click to drawer, click to first byte.** "Start review" on a PR with no
   worktree, on a PR with a live session, and from ⌘K with a URL: time from
   the click (or Return) to the drawer on screen — expected within a frame
   or two in the first two cases — and to the terminal's first output. A
   signpost around `singleReviewLaunch` and one in `TerminalPane` where
   `hasOutput` turns true would give both.
2. **Body passes while a review starts.** Count the passes of
   `PRWorkspaceView.body` and `SplitDiffView.body` (`Self._printChanges()`,
   or the SwiftUI instrument) from the click to an idle session. Expected:
   none caused by a session transition, one when the drawer first shows a
   live session. This is the claim of items 12 and 13 and the one most worth
   checking: `.equatable()` skips a body only if nothing else invalidates
   it.
3. **Time to the first diff** on a PR never opened: before, the sum of three
   `gh` calls; after, the slowest. And the count of `gh` processes for one
   tab opened on a three-hour-old row that moved (expected: five — the row
   and four pieces — where there could be nine).
4. **⌘K to first keystroke shown**, and keystroke to list, with a few
   hundred sessions in the history and a session streaming in the
   background. The streaming case is the one no change here addresses.
5. **Typing in the verdict bar and dragging the drawer** over a 5,000-line
   diff: the main thread should show the bar, not the diff.
6. **Browse**: a filter keystroke and a sort click over 300 rows, and over
   the catalog of a large organisation.

## Left open

- Browse still re-runs on every session transition: `browseRows(in:)` reads
  `sessions` through `reviewSessionRank`. With the memo a transition that
  changes no rank costs one row build and one comparison. Ranks stored in
  the model, written when one changes, would remove the pass.
- The query is still tokenised once per row while a filter is typed
  (`PRBrowseRow.matches(query:)`); a `matches(tokens:)` in LoomGit, with a
  probe beside `DiffRowsProbes` for the filter and the sort, would close it.
- `claudeTheme(for:)` still rewrites the theme files on the main actor when
  the Claude theme sync is on.
- A load started by a button (`load(refresh: true)` after a comment or a
  verdict) is not a child of the view's task and can overlap the task's own
  load; the last to land wins, as before.
- No timing probe exists for LoomApp: it is an executable target with no
  test target. What can be probed has to live in LoomGit or LoomUI.
