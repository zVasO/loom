import AppKit
import LoomCore
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
///   theme followed for its colours only), `core` (the main screens only).
/// - `LOOM_TOUR_OUT`: where the PNGs and `tour.json` go.
/// - `LOOM_TOUR_PROJECT`: a folder opened as a project, with three sessions
///   in it — the first in a worktree of its own when it is a git
///   repository. Where the tour runs has no claude: `PATH` leads to a
///   stand-in (`Tests/ThemeTour/bin/claude`), which also writes the
///   conversation the chat view shows.
/// - `LOOM_TOUR_CAPTURE`: `screen` (the display, through `screencapture`;
///   when unsaid) or `view` (the window drawing itself: no blur, no sheet
///   over it — for a Mac that refuses the screen to be read).
@MainActor
final class ThemeTour {

    /// A sheet over the window.
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

        var label: String {
            var parts = [theme, dark ? "dark" : "light"]
            if colorsOnly { parts.append("colours") }
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
                                            "chat-narrow", "git-panel", "side-panel", "context", "overview",
                                            "prs", "workflows", "extensions"]
        + settingsStops.map { "settings-" + $0.rawValue }
        + ["theme-import", "palette", "new-session", "usage"]
    private static let coreScreens: Set<String> = ["projects", "sessions", "chat", "chat-narrow", "git-panel", "overview",
                                                   "workflows", "settings-general", "settings-themes",
                                                   "theme-import", "palette"]
    /// How long a screen takes to settle before its picture, in milliseconds.
    /// The chat view finds and reads the conversation's file first.
    private static let settling: [String: Int] = ["sessions": 1_200, "chat": 2_500, "chat-narrow": 2_500,
                                                  "git-panel": 1_500,
                                                  "project-git": 1_500, "theme-import": 2_500]

    private let model: AppModel
    private let driver: Driver
    private let environment = ProcessInfo.processInfo.environment
    private var window: NSWindow?
    private var sessions: [SessionID] = []
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
            let screens = Self.screens.filter { !stop.core || Self.coreScreens.contains($0) }
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
            log("\(stop.label): \(shots.count) of \(screens.count) screens")
            index.append(["stop": stop.label, "folder": folder.lastPathComponent,
                          "design": design, "screens": shots])
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
        if let builtIn = ThemeFamily.builtins.first(where: { $0.name.lowercased() == stop.theme.lowercased() }) {
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
        case "git-panel":
            ask("git")
            return true
        case "context":
            ask("context-close")
            return true
        case "theme-import":
            ask("theme-import-close")
            return true
        case "palette", "new-session", "usage":
            driver.present(nil)
            return true
        default:
            return false
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
