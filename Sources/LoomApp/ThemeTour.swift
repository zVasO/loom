import AppKit
import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// `LOOM_AUTOTEST=themes swift run LoomApp` (ContentView): Loom shows itself
/// under each theme of a plan, screen after screen, and saves what the
/// display shows of its window. The check no unit test makes: that a whole
/// imported theme — radius, spacing, fonts, shadows — leaves every screen
/// in one piece, and that a built-in one is drawn as before.
///
/// - `LOOM_SUPPORT_DIR` (required): the tour adds themes, a project and
///   sessions — never in your own data.
/// - `LOOM_TOUR_PLAN`: the stops, comma-separated, each `theme[:option…]`.
///   A theme is a built-in family's name, or `<theme>.css` in
///   `LOOM_TOUR_THEMES` — a tweakcn export, read as the import sheet reads
///   it. Options: `light` or `dark` (dark when unsaid), `colours` (the
///   theme followed for its colours only), `core` (the main screens only),
///   `keys` (no screen: the keyboard walk, see `LOOM_TOUR_REVIEW`).
/// - `LOOM_TOUR_OUT`: where the PNGs and `tour.json` go.
/// - `LOOM_TOUR_PROJECT`: a folder opened as a project, with three sessions
///   in it — the first in a worktree of its own when it is a git
///   repository. Where the tour runs has no claude: `PATH` leads to a
///   stand-in (`Tests/ThemeTour/bin/claude`), which also writes the
///   conversation the chat view shows.
/// - `LOOM_TOUR_REVIEW`: a pull request the `keys` walk starts a review of,
///   as it would be typed in the palette — typed key by key, so lowercase
///   letters, digits, `/`, `.` and `-` only (`github.com/owner/repo/pull/12`).
///   Needs `gh` signed in; unsaid, the walk stops before any review.
/// - `LOOM_TOUR_SAMPLE`: set, the walk has `/usr/bin/sample` read the app's
///   threads while a review launches (`sample-*.txt` beside the pictures):
///   what the main thread was doing. The sampling slows the app: the
///   durations of such a walk are not to be read.
/// - `LOOM_TOUR_CAPTURE`: `screen` (the display, through `screencapture`;
///   when unsaid) or `view` (the window drawing itself: no blur, no sheet
///   over it — for a Mac that refuses the screen to be read). The palette
///   is an overlay of the window (ADR-0024): it is in both.
@MainActor
final class ThemeTour {

    /// What shows over the window: a sheet — or the palette, drawn in it.
    enum Overlay { case palette, usage, newSession }

    /// What the tour asks of the window: `ContentView` holds that state.
    struct Driver {
        let show: @MainActor (MainTab) -> Void
        let select: @MainActor (DetailSelection?) -> Void
        let focusSettings: @MainActor (SettingsAnchor) -> Void
        let present: @MainActor (Overlay?) -> Void
    }

    /// One stop of the plan: a theme, a variant, whole or colours only.
    struct Stop: Equatable {
        var theme: String
        var dark = true
        var colorsOnly = false
        var core = false
        /// The keyboard walk instead of the screens.
        var keys = false
        /// The scroll probe instead of the screens.
        var scroll = false

        var label: String {
            var parts = [theme, dark ? "dark" : "light"]
            if colorsOnly { parts.append("colours") }
            if keys { parts.append("keys") }
            if scroll { parts.append("scroll") }
            return parts.joined(separator: "-")
        }

        init?(_ text: String) {
            let parts = text.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            theme = name
            for option in parts.dropFirst() {
                switch option {
                case "light": dark = false
                case "dark": dark = true
                case "colours", "colors": colorsOnly = true
                case "core": core = true
                case "keys": keys = true
                case "scroll": scroll = true
                default: return nil
                }
            }
        }

        static func plan(_ text: String) -> [Stop] {
            text.split(separator: ",").compactMap { Stop(String($0)) }
        }
    }

    /// The Settings sections worth a picture: one per kind of content.
    private static let settingsStops: [SettingsAnchor] = [
        .general, .sessions, .badges, .agentEngine, .scheduledReviews,
        .appearance, .themes, .documents, .projects,
    ]
    private static let screens: [String] = ["projects", "project-git", "project-files", "sessions", "chat",
                                            "chat-narrow", "git-panel", "git-history", "side-panel", "context", "overview",
                                            "prs", "workflows", "extensions"]
        + settingsStops.map { "settings-" + $0.rawValue }
        + ["theme-import", "palette", "palette-review", "new-session", "usage"]
    private static let coreScreens: Set<String> = ["projects", "sessions", "chat", "chat-narrow", "git-panel",
                                                   "git-history", "overview",
                                                   "workflows", "settings-general", "settings-themes",
                                                   "theme-import", "palette", "palette-review"]
    /// How long a screen takes to settle before its picture, in milliseconds.
    /// The chat view finds and reads the conversation's file first.
    private static let settling: [String: Int] = ["sessions": 1_200, "chat": 2_500, "chat-narrow": 2_500,
                                                  "git-panel": 1_500, "git-history": 3_500,
                                                  "project-git": 1_500, "theme-import": 2_500]

    private let model: AppModel
    private let driver: Driver
    private let environment = ProcessInfo.processInfo.environment
    private var window: NSWindow?
    private var sessions: [SessionID] = []
    private var project: ProjectID?
    /// The keyboard walk's pictures, and what had the keyboard at each.
    private var walkShots: [String] = []
    private var walkNotes: [[String: Any]] = []
    /// The main thread's silences during the walk (see `watchStalls`).
    private var walkStalls: [[String: Any]] = []
    private var walkStep = "start"
    /// Counts the walk's pictures: taking one holds the main thread.
    private var walkCaptures = 0
    /// The stop being shown.
    private var current: Stop?
    private var readsScreen = true
    private var failures: [String] = []

    init(model: AppModel, driver: Driver) {
        self.model = model
        self.driver = driver
    }

    /// The whole tour. True when every stop was shown and every picture saved.
    func run() async -> Bool {
        guard environment["LOOM_SUPPORT_DIR"] != nil else {
            log("LOOM_SUPPORT_DIR is required: the tour never writes in your own data")
            return false
        }
        let stops = Stop.plan(environment["LOOM_TOUR_PLAN"] ?? "loom:dark,loom:light")
        guard !stops.isEmpty else {
            log("LOOM_TOUR_PLAN names no stop")
            return false
        }
        let output = URL(fileURLWithPath: environment["LOOM_TOUR_OUT"] ?? "theme-tour")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        readsScreen = environment["LOOM_TOUR_CAPTURE"] != "view"

        // The model has started and the window is on screen.
        try? await Task.sleep(for: .milliseconds(1_500))
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else {
            log("no window")
            return false
        }
        self.window = window
        place(window)
        await seed()

        let store = ThemeStore.shared
        let themeBefore = store.globalFamilyName
        let modeBefore = store.appearanceMode

        var index: [[String: Any]] = []
        for (number, stop) in stops.enumerated() {
            guard let design = await apply(stop) else {
                failures.append(stop.label)
                continue
            }
            let folder = output.appendingPathComponent(String(format: "%02d-%@", number + 1, stop.label))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var shots: [String] = []
            let screens = stop.keys || stop.scroll ? [] : Self.screens.filter { !stop.core || Self.coreScreens.contains($0) }
            for (order, screen) in screens.enumerated() {
                enter(screen)
                try? await Task.sleep(for: .milliseconds(Self.settling[screen] ?? 800))
                let name = String(format: "%02d-%@.png", order + 1, screen)
                if number == 0, order == 0 { calibrate(in: output) }
                if capture(to: folder.appendingPathComponent(name)) {
                    shots.append(name)
                } else {
                    failures.append("\(stop.label)/\(screen)")
                }
                if leave(screen) { try? await Task.sleep(for: .milliseconds(500)) }
            }
            var entry: [String: Any] = ["stop": stop.label, "folder": folder.lastPathComponent, "design": design]
            if stop.keys {
                if number == 0 { calibrate(in: output) }
                await keyboardWalk(into: folder)
                shots = walkShots
                entry["keyboard"] = walkNotes
                entry["stalls"] = walkStalls
            }
            if stop.scroll {
                entry["scroll"] = await scrollWalk(into: folder)
                shots = walkShots
            }
            log("\(stop.label): \(shots.count) of \(stop.keys || stop.scroll ? shots.count : screens.count) screens")
            entry["screens"] = shots
            index.append(entry)
        }

        store.setAppearanceMode(modeBefore)
        store.setGlobalTheme(themeBefore)
        write(index, to: output)
        if !failures.isEmpty { log("failed: " + failures.joined(separator: ", ")) }
        return failures.isEmpty
    }

    // MARK: The window and what it holds

    /// A laptop's window, at the top left of the screen — the size the
    /// pictures are read at.
    private func place(_ window: NSWindow) {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: min(1_440, visible.width), height: min(900, visible.height))
        window.setFrame(NSRect(x: visible.minX, y: visible.maxY - size.height,
                               width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A project and three sessions, so no screen is shown empty.
    private func seed() async {
        guard let path = environment["LOOM_TOUR_PROJECT"] else { return }
        let project = await model.addProject(at: URL(fileURLWithPath: path))
        self.project = project
        let wanted: [(title: String, badges: [String])] = [
            ("Follow an imported theme to the letter", ["PR #42", "review"]),
            ("Fix the flaky login test", ["wip"]),
            ("Settings open at once", []),
        ]
        for (order, session) in wanted.enumerated() {
            // The first one in a worktree of its own: the stand-in claude
            // changes a file there, and the Git panel has a diff to show.
            if let id = await model.launchSession(in: project,
                                                  placement: order == 0 ? .newWorktree : .projectFolder,
                                                  title: session.title, badges: session.badges) {
                sessions.append(id)
            }
        }
        // The stand-in claude has painted its screen.
        try? await Task.sleep(for: .seconds(2))
    }

    /// Shows the app under a stop's theme; what the theme brings beyond its
    /// colours comes back for the index. nil when the theme cannot be had.
    private func apply(_ stop: Stop) async -> [String: Any]? {
        let store = ThemeStore.shared
        current = stop
        let name: String
        if let builtIn = (ThemeFamily.builtins + ThemeFamily.gallery)
            .first(where: { $0.name.lowercased() == stop.theme.lowercased() }) {
            name = builtIn.name
        } else {
            guard let directory = environment["LOOM_TOUR_THEMES"] else {
                log("\(stop.theme): no LOOM_TOUR_THEMES to read it from")
                return nil
            }
            let file = URL(fileURLWithPath: directory).appendingPathComponent(stop.theme + ".css")
            do {
                let css = try String(contentsOf: file, encoding: .utf8)
                // As the import sheet does: read, fonts fetched, saved.
                var family = try await store.importTweakcn(css)
                family.name = stop.theme
                family = await store.withFonts(family)
                family.colorsOnly = stop.colorsOnly
                try store.addFamily(family)
                name = family.name
            } catch {
                log("\(stop.theme): \(error)")
                return nil
            }
        }
        store.setAppearanceMode(stop.dark ? .dark : .light)
        store.setGlobalTheme(name)
        NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
        try? await Task.sleep(for: .seconds(1))

        var summary: [String: Any] = [:]
        if let design = store.palette.design {
            if let radius = design.radius { summary["radius"] = radius }
            if let spacing = design.spacing { summary["spacing"] = spacing }
            if let letterSpacing = design.letterSpacing { summary["letterSpacing"] = letterSpacing }
            if let stack = design.fontSans {
                summary["sans"] = ThemeFonts.shared.familyName(for: stack) ?? "system"
            }
            if let stack = design.fontMono {
                summary["mono"] = ThemeFonts.shared.familyName(for: stack) ?? "system"
            }
            if let shadow = design.shadow {
                summary["shadow"] = "\(shadow.x) \(shadow.y) \(shadow.blur) \(shadow.spread) @\(shadow.opacity)"
            }
        }
        return summary
    }

    // MARK: Screens

    private func enter(_ screen: String) {
        if screen.hasPrefix("settings-"),
           let anchor = SettingsAnchor(rawValue: String(screen.dropFirst("settings-".count))) {
            driver.show(.settings)
            driver.focusSettings(anchor)
            return
        }
        switch screen {
        case "projects": driver.show(.projects)
        case "project-git", "project-files":
            driver.show(.projects)
            ask(screen)
        case "git-history":
            // The Git tab, then its history: the latest commit and its files.
            driver.show(.sessions)
            driver.select(sessions.first.map { DetailSelection.git($0) })
            if let first = sessions.first { model.gitTabs.insert(first) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.ask("git-history")
            }
        case "sessions", "chat", "chat-narrow", "side-panel", "git-panel", "context":
            driver.show(.sessions)
            driver.select(sessions.first.map { DetailSelection.session($0) })
            if screen == "chat" || screen == "chat-narrow" {
                ask("chat")
                // The fleet panel folded: the conversation gets the height
                // to show more than its last answer. And once beside the
                // browser: half the width, where a table has to wrap.
                NotificationCenter.default.post(name: .loomToggleFleetPanel, object: nil)
                if screen == "chat-narrow" {
                    NotificationCenter.default.post(name: .loomToggleSidePanel, object: nil)
                }
            } else if screen == "side-panel" {
                NotificationCenter.default.post(name: .loomToggleSidePanel, object: nil)
            } else if screen == "git-panel" {
                ask("git")
            } else if screen == "context" {
                ask("context")
            }
        case "theme-import":
            driver.show(.settings)
            ask("theme-import", text: importText())
        case "overview": driver.show(.overview)
        case "prs": driver.show(.prs)
        case "workflows": driver.show(.workflows)
        case "extensions": driver.show(.extensions)
        case "palette": driver.present(.palette)
        // The palette asking for a pull request ("Review code"): its host
        // opens it on that prompt.
        case "palette-review": ask("palette-review")
        case "new-session": driver.present(.newSession)
        case "usage": driver.present(.usage)
        default: break
        }
    }

    /// Undoes what a screen put over the window. True when something was.
    private func leave(_ screen: String) -> Bool {
        switch screen {
        case "chat", "chat-narrow":
            // The screens after it are the terminal's, over the fleet panel.
            if screen == "chat-narrow" {
                NotificationCenter.default.post(name: .loomToggleSidePanel, object: nil)
            }
            NotificationCenter.default.post(name: .loomToggleFleetPanel, object: nil)
            ask("terminal")
            return true
        case "side-panel":
            NotificationCenter.default.post(name: .loomToggleSidePanel, object: nil)
            return true
        case "project-git", "project-files":
            ask("project-overview")
            return false
        case "git-panel", "git-history":
            // The Git tab took the session's place: back to its terminal.
            driver.select(sessions.first.map { DetailSelection.session($0) })
            return true
        case "context":
            ask("context-close")
            return true
        case "theme-import":
            ask("theme-import-close")
            return true
        case "palette", "palette-review", "new-session", "usage":
            driver.present(nil)
            return true
        default:
            return false
        }
    }

    // MARK: The scroll probe

    /// How smoothly each long screen scrolls: its scroll view is swept down
    /// and back a frame at a time, and the time between two frames is what
    /// the main thread took to lay out and draw one. 16–18 ms is a frame
    /// kept; past 34, one was dropped (`tour.json`, `scroll`). With
    /// `LOOM_TOUR_SAMPLE`, the threads are sampled during each sweep.
    private func scrollWalk(into folder: URL) async -> [[String: Any]] {
        walkShots = []
        walkNotes = []
        var results: [[String: Any]] = []
        let session = sessions.first.map { DetailSelection.session($0) }
        let probes: [(String, @MainActor () -> Void)] = [
            ("settings", { [driver] in driver.show(.settings); driver.focusSettings(.general) }),
            ("terminal", { [driver] in driver.show(.sessions); driver.select(session) }),
            ("chat", { [weak self, driver] in driver.show(.sessions); driver.select(session); self?.ask("chat") }),
            ("git-diff", { [weak self, driver] in
                driver.show(.sessions); driver.select(session); self?.ask("terminal"); self?.ask("git")
            }),
            ("projects", { [driver] in driver.show(.projects) }),
            ("prs", { [driver] in driver.show(.prs) }),
            ("overview", { [driver] in driver.show(.overview) }),
        ]
        for (name, enter) in probes {
            enter()
            try? await Task.sleep(for: .milliseconds(name == "git-diff" ? 4_000 : 2_500))
            await picture("scroll-" + name, in: folder, after: 0)
            await sample("scroll-" + name, seconds: 6, into: folder)
            results.append(await sweep(name))
        }
        return results
    }

    /// The tallest scrolling area of the window: the screen's main list.
    private func mainScrollView() -> NSScrollView? {
        var best: NSScrollView?
        var bestArea: CGFloat = 0
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 40 {
                let area = scroll.frame.width * scroll.frame.height
                if area > bestArea {
                    best = scroll
                    bestArea = area
                }
            }
            view.subviews.forEach(visit)
        }
        if let root = window?.contentView { visit(root) }
        return best
    }

    private func sweep(_ name: String) async -> [String: Any] {
        guard let scroll = mainScrollView(), let document = scroll.documentView else {
            return ["screen": name, "found": false]
        }
        let clip = scroll.contentView
        let range = max(0, document.frame.height - clip.bounds.height)
        let step: CGFloat = 36
        let frames = 150
        var intervals: [Double] = []
        // What the main thread spends producing one frame after the scroll
        // moved: layout, SwiftUI's update, drawing, the commit — timed by
        // asking for them at once instead of waiting for the next turn.
        var work: [Double] = []
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
        scroll.reflectScrolledClipView(clip)
        try? await Task.sleep(for: .milliseconds(400))
        var last = ProcessInfo.processInfo.systemUptime
        for frame in 0..<(frames * 2) {
            let travelled = CGFloat(frame < frames ? frame : frames * 2 - frame) * step
            // The document may have grown: a lazy list learns its height as it goes.
            let limit = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(limit, travelled)))
            scroll.reflectScrolledClipView(clip)
            let began = ProcessInfo.processInfo.systemUptime
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
            work.append((ProcessInfo.processInfo.systemUptime - began) * 1_000)
            try? await Task.sleep(for: .milliseconds(16))
            let now = ProcessInfo.processInfo.systemUptime
            intervals.append((now - last) * 1_000)
            last = now
        }
        func at(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return (sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] * 10).rounded() / 10
        }
        func at(_ fraction: Double) -> Double { at(intervals, fraction) }
        return ["screen": name, "found": true, "range": Int(range),
                "workMedian": at(work, 0.5), "workP95": at(work, 0.95), "workMax": at(work, 1),
                "workOver16": work.filter { $0 > 16.7 }.count,
                "median": at(0.5), "p95": at(0.95), "max": at(1),
                "dropped": intervals.filter { $0 > 34 }.count, "frames": intervals.count]
    }

    // MARK: The keyboard walk

    /// What no picture of a state shows: that the palette answers the
    /// keyboard. ⌘K, a search, Tab, "Review code", its prompt refusing and
    /// taking an answer, Esc twice, and the keyboard back where it was —
    /// pressed as keys, through the app's own event queue, each step with
    /// its picture and a note of what had the keyboard (`tour.json`).
    private func keyboardWalk(into folder: URL) async {
        walkShots = []
        walkNotes = []
        walkStalls = []
        let stalls = watchStalls()
        defer { stalls.cancel() }
        // First, while claude's stand-in still waits on its prompt: no key
        // has answered it yet.
        await chatWalk(into: folder)
        driver.show(.sessions)
        driver.select(sessions.first.map { DetailSelection.session($0) })
        await picture("terminal", in: folder, after: 1_500)
        await typeText("ls")
        await picture("terminal-typed", in: folder)

        clockPalette("first")
        await press("k", code: 40, modifiers: .command)
        await picture("palette", in: folder)
        await typeText("re")
        await picture("palette-search", in: folder)
        await press("\t", code: 48)
        await typeText("v")
        await picture("palette-after-tab", in: folder)
        await press("\r", code: 36)
        await picture("prompt", in: folder)
        await typeText("nope")
        await press("\r", code: 36)
        await picture("prompt-refused", in: folder)
        await press("\u{1B}", code: 53)
        await picture("back-to-list", in: folder)
        clock(["terminal-has-the-keyboard-back": { [weak self] in
            !(self?.window?.firstResponder is NSTextView) && self?.window?.firstResponder !== self?.window
        }])
        await press("\u{1B}", code: 53)
        await picture("closed", in: folder)
        await typeText("pwd")
        await picture("closed-typed", in: folder)
        // ⌘⇧R: the palette, already asking for the pull request.
        await press("r", code: 15, modifiers: [.command, .shift])
        await picture("shortcut-review", in: folder)
        await press("\u{1B}", code: 53)
        await press("\u{1B}", code: 53)

        // ⌘K is a toggle: pressed again, it closes what it opened.
        await press("k", code: 40, modifiers: .command)
        await typeText("set")
        await press("k", code: 40, modifiers: .command)
        await picture("toggled-closed", in: folder)
        // ↓ walks the list, Return runs the row it landed on.
        clockPalette("again")
        await press("k", code: 40, modifiers: .command)
        await press(Self.downArrow, code: 125, modifiers: [.function, .numericPad])
        await press(Self.downArrow, code: 125, modifiers: [.function, .numericPad])
        await picture("arrow-down-twice", in: folder)
        await press("\r", code: 36)
        await picture("arrow-row-run", in: folder, after: 1_200)

        guard let reference = environment["LOOM_TOUR_REVIEW"], !reference.isEmpty else { return }
        await press("k", code: 40, modifiers: .command)
        await typeText("rev")
        await press("\r", code: 36)
        await typeText(reference)
        await picture("prompt-answer", in: folder)
        await sample("url-review", seconds: 6, into: folder)
        if let project, let number = PRReference.parse(reference)?.number {
            let model = self.model
            clock(["review-shows-in-the-tab": { model.prMode == .review && (!model.prReviewsOpening.isEmpty
                                                    || model.prTabs.contains(PRTab.key(project, number))) },
                   "review-tab-open": { model.prTabs.contains(PRTab.key(project, number)) },
                   "review-session-started": { model.reviewSession(forPR: number, in: project) != nil }])
        }
        await press("\r", code: 36)
        // What Return shows at once, then as the row, the checkout and the
        // session land.
        await picture("review-at-once", in: folder, after: 250)
        await picture("review-3s", in: folder, after: 3_000)
        await picture("review-12s", in: folder, after: 9_000)
        await picture("review-25s", in: folder, after: 13_000)
        // The list the tab browses, then a review started from one of its
        // rows, as a click on "Start review" starts it.
        await sample("to-browse", seconds: 3, into: folder)
        model.prMode = .browse
        await picture("browse", in: folder, after: 6_000)
        if let project,
           let row = model.prs(for: project).first(where: { model.reviewSession(forPR: $0.number, in: project) == nil }) {
            let model = self.model
            await sample("row-review", seconds: 7, into: folder)
            clock(["row-review-drawer-open": { model.prTabs.tab(PRTab.key(project, row.number))?.drawerOpen == true },
                   "row-review-session-started": { model.reviewSession(forPR: row.number, in: project) != nil }])
            model.startPRReview(row, in: project)
            await picture("row-review-at-once", in: folder, after: 250)
            await picture("row-review-3s", in: folder, after: 3_000)
            await picture("row-review-15s", in: folder, after: 12_000)
        }
        clockPalette("over-a-review")
        await press("k", code: 40, modifiers: .command)
        await picture("palette-over-review", in: folder)
        await press("\u{1B}", code: 53)
        await typeText("ok")
        await picture("review-drawer-typed", in: folder)

        // The palette's opening, three times over each kind of screen: what
        // is under it should not make it slower.
        await openings("over-review-and-drawer")
        if let tab = model.prTabs.activeID {
            model.setPRTabDrawer(open: false, for: tab)
            await openings("over-review")
        }
        model.prMode = .browse
        await openings("over-browse")
        driver.show(.settings)
        await openings("over-settings")
        driver.show(.sessions)
        await openings("over-sessions")
    }

    /// Has the app's threads sampled for a few seconds from now
    /// (`LOOM_TOUR_SAMPLE`): the report says where the main thread was.
    private func sample(_ name: String, seconds: Int, into folder: URL) async {
        guard environment["LOOM_TOUR_SAMPLE"] != nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(seconds), "2",
                             "-file", folder.appendingPathComponent("sample-\(name).txt").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("sample: \(error)")
            return
        }
        // It attaches first.
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// The chat view: the choice claude asks for (with LOOM_TOUR_PERMISSION),
    /// an image in a message, and a picture pasted with ⌘V into the field.
    private func chatWalk(into folder: URL) async {
        driver.show(.sessions)
        driver.select(sessions.first.map { DetailSelection.session($0) })
        try? await Task.sleep(for: .milliseconds(1_200))
        ask("chat")
        await picture("chat", in: folder, after: 2_500)
        let pasted = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
            NSColor(calibratedRed: 0.17, green: 0.24, blue: 0.31, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.9, green: 0.39, blue: 0.42, alpha: 1).setFill()
            NSRect(x: 110, y: 80, width: 100, height: 40).fill()
            return true
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([pasted])
        await press("v", code: 9, modifiers: .command)
        await picture("chat-pasted", in: folder)
        ask("terminal")
        try? await Task.sleep(for: .milliseconds(800))
    }

    private func openings(_ place: String) async {
        try? await Task.sleep(for: .milliseconds(1_500))
        walkStep = place
        for round in 1...3 {
            clockPalette("\(place)-\(round)")
            await press("k", code: 40, modifiers: .command)
            try? await Task.sleep(for: .milliseconds(600))
            await press("\u{1B}", code: 53)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The main thread's silences: a task that asks for it every few
    /// milliseconds notes each time it waited more than 60 ms — the app
    /// answered nothing meanwhile — and the step it was in (`tour.json`,
    /// `stalls`).
    private func watchStalls() -> Task<Void, Never> {
        let start = ProcessInfo.processInfo.systemUptime
        return Task { @MainActor [weak self] in
            var last = ProcessInfo.processInfo.systemUptime
            var captures = self?.walkCaptures ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ProcessInfo.processInfo.systemUptime
                let waited = Int(((now - last) * 1_000).rounded())
                guard let self else { return }
                // A picture taken meanwhile is the tour's doing, not the app's.
                if waited > 60, captures == self.walkCaptures {
                    self.walkStalls.append(["at": Int(((last - start) * 1_000).rounded()),
                                            "ms": waited, "after": self.walkStep])
                }
                captures = self.walkCaptures
                last = now
            }
        }
    }

    private static let downArrow = String(Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!))

    /// The keys the walk types, by their place on an ANSI keyboard.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34,
        "p": 35, "l": 37, "j": 38, "k": 40, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49,
    ]

    /// A key pressed and released, posted to the app's event queue: it
    /// takes the road a real one takes — the key monitors, the shortcuts,
    /// then whatever has the keyboard.
    private func press(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) async {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func typeText(_ text: String) async {
        for character in text {
            guard let code = Self.keyCodes[character] else { continue }
            await press(String(character), code: code)
        }
    }

    /// ⌘K is about to be pressed: how long until the palette is up, and
    /// until its field has the keyboard.
    private func clockPalette(_ opening: String) {
        clock(["palette-\(opening)-up": { WindowOverlay.isUp },
               "palette-\(opening)-has-the-keyboard": { [weak self] in self?.window?.firstResponder is NSTextView }])
    }

    /// Notes how long from now each mark takes to come true, in milliseconds
    /// (`tour.json`, `timing`) — looked at every few milliseconds beside
    /// the walk, for half a minute at most. On the tour's Mac: an order of
    /// magnitude, not a bound.
    private func clock(_ marks: [String: @MainActor () -> Bool]) {
        let start = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            var waiting = marks
            while !waiting.isEmpty, ProcessInfo.processInfo.systemUptime - start < 30 {
                for (name, reached) in waiting where reached() {
                    let elapsed = Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded())
                    self?.walkNotes.append(["timing": name, "ms": elapsed])
                    waiting[name] = nil
                }
                try? await Task.sleep(for: .milliseconds(4))
            }
            for name in waiting.keys.sorted() { self?.walkNotes.append(["timing": name, "ms": -1]) }
        }
    }

    /// A step's picture, and what had the keyboard when it was taken: the
    /// field's text when a field did.
    private func picture(_ step: String, in folder: URL, after milliseconds: Int = 700) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        walkStep = step
        let responder = window?.firstResponder
        var note: [String: Any] = ["step": step, "active": NSApp.isActive,
                                   "key": window?.isKeyWindow ?? false,
                                   "responder": responder.map { String(describing: Swift.type(of: $0)) } ?? "none"]
        if let editor = responder as? NSTextView { note["text"] = editor.string }
        walkNotes.append(note)
        let name = String(format: "%02d-%@.png", walkShots.count + 1, step)
        walkCaptures += 1
        if capture(to: folder.appendingPathComponent(name)) {
            walkShots.append(name)
        } else {
            failures.append("\(current?.label ?? "keys")/\(step)")
        }
    }

    /// Asks a view for a state only it holds (`Notification.Name.loomTourShow`).
    private func ask(_ state: String, text: String? = nil) {
        NotificationCenter.default.post(name: .loomTourShow, object: state,
                                        userInfo: text.map { ["text": $0] })
    }

    /// What the import sheet is opened on: the stop's own export, or — for
    /// a built-in theme — shadcn's default one.
    private func importText() -> String? {
        guard let directory = environment["LOOM_TOUR_THEMES"] else { return nil }
        let folder = URL(fileURLWithPath: directory)
        let names = [current?.theme, "default"].compactMap { $0 }
        return names.lazy
            .compactMap { try? String(contentsOf: folder.appendingPathComponent($0 + ".css"), encoding: .utf8) }
            .first
    }

    // MARK: Pictures

    private func capture(to url: URL) -> Bool {
        guard let window else { return false }
        if readsScreen, screenshot(of: window, to: url) { return true }
        return drawing(of: window, to: url)
    }

    /// The first screen both ways, and the whole display: what tells a
    /// display that cannot be read (a picture of the desktop alone) from a
    /// window that is wrong.
    private func calibrate(in output: URL) {
        guard let window else { return }
        let onScreen = screenshot(of: window, to: output.appendingPathComponent("00-calibration.screen.png"))
        let drawn = drawing(of: window, to: output.appendingPathComponent("00-calibration.view.png"))
        let display = run("/usr/sbin/screencapture",
                          ["-x", "-t", "png", output.appendingPathComponent("00-display.png").path])
        let screen = NSScreen.screens.first?.frame ?? .zero
        log("calibration: screen \(Int(screen.width))x\(Int(screen.height)), window \(window.frame), "
            + "scale \(window.backingScaleFactor), screencapture \(onScreen), drawing \(drawn), display \(display)")
    }

    /// What the display shows where the window is — sheets included.
    private func screenshot(of window: NSWindow, to url: URL) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let frame = window.frame
        // `screencapture -R` counts from the top left of the main display.
        let rect = [frame.minX, primary.frame.maxY - frame.maxY, frame.width, frame.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
        try? FileManager.default.removeItem(at: url)
        guard run("/usr/sbin/screencapture", ["-x", "-R", rect, "-t", "png", url.path]) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 2_000
    }

    /// The window drawing itself into a bitmap.
    private func drawing(of window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func write(_ index: [[String: Any]], to output: URL) {
        let document: [String: Any] = ["capture": readsScreen ? "screen" : "view",
                                       "failures": failures, "stops": index]
        guard let data = try? JSONSerialization.data(withJSONObject: document,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: output.appendingPathComponent("tour.json"))
    }

    private func log(_ message: String) {
        print("theme tour: " + message)
        fflush(stdout)
    }
}
