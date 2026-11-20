import LoomAgents
import LoomCore
import LoomUI
import SwiftUI

/// "Activity": what a session — or every session on this machine — reached
/// for: MCP servers, skills, sub-agents, hooks, slash commands, tools, each
/// ranked by use, and what was offered and never called. Read from claude's
/// own records (`ClaudeActivity`), off the main actor; the sheet only displays.
/// Opens from the bars in a session's header (that session) and from the
/// bars in the navbar (all of them, over a window).
struct ActivitySheet: View {
    enum Scope: Equatable, Sendable {
        /// One session, by its native id; its title for the header.
        case session(native: SessionID, title: String)
        case everywhere
    }

    enum Window: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var label: String { "\(rawValue)d" }
    }

    let scope: Scope
    let onClose: () -> Void

    @State private var tally: ActivityTally?
    @State private var sessions = 0
    @State private var loaded = false
    @State private var refreshing = false
    @State private var window: Window = .month
    /// Rankings shown whole, and MCP servers opened on their tools.
    @State private var expanded: Set<String> = []

    /// How many rows a ranking shows before "Show all".
    private static let shown = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DefaultTheme.cardBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: DefaultTheme.space(18)) {
                    Text(intro)
                        .themeFont(size: 12)
                        .foregroundStyle(DefaultTheme.secondaryText)
                    if let tally, !tally.isEmpty {
                        tiles(tally)
                        HStack(alignment: .top, spacing: DefaultTheme.space(14)) {
                            VStack(spacing: DefaultTheme.space(14)) {
                                servers(tally)
                                ranking("Hooks", icon: "link", kind: .hook, tally: tally,
                                        empty: "No hook left a line.",
                                        note: "Counted from what claude writes of a hook: one that ran silently is not here.")
                                ranking("Slash commands", icon: "terminal", kind: .command, tally: tally,
                                        empty: "None typed.")
                            }
                            VStack(spacing: DefaultTheme.space(14)) {
                                ranking("Skills", icon: "sparkles", kind: .skill, tally: tally,
                                        empty: "None loaded.", unused: tally.unusedSkills)
                                ranking("Sub-agents", icon: "person.2", kind: .agent, tally: tally,
                                        empty: "None started.")
                                ranking("Tools", icon: "wrench", kind: .tool, tally: tally,
                                        empty: "None called.")
                            }
                        }
                    } else if loaded {
                        Text(scope == .everywhere
                             ? "No session did anything in this window."
                             : "Nothing recorded yet — claude has not called a tool in this session.")
                            .themeFont(size: 12)
                            .foregroundStyle(DefaultTheme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        HStack(spacing: DefaultTheme.space(8)) {
                            ProgressView().controlSize(.small)
                            Text(scope == .everywhere ? "Reading local session records…"
                                                      : "Reading the session's records…")
                                .themeFont(size: 12).foregroundStyle(DefaultTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding(DefaultTheme.space(24))
            }
        }
        .frame(width: 880, height: 780)
        .background(DefaultTheme.surface)
        .preferredColorScheme(DefaultTheme.colorScheme)
        .font(DefaultTheme.bodyFont)
        .tint(DefaultTheme.controlTint)
        .task(id: window) { await refresh() }
    }

    private var intro: String {
        switch scope {
        case .session:
            return "Counted from this session's own records, its sub-agents included."
        case .everywhere:
            let count = loaded ? " — \(sessions) session\(sessions == 1 ? "" : "s")" : ""
            return "Every claude session on this machine over the last \(window.rawValue) days\(count). Nothing leaves it."
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: DefaultTheme.space(10)) {
            AppIcon("chart.bar", size: 17)
                .foregroundStyle(DefaultTheme.accentInk)
            VStack(alignment: .leading, spacing: DefaultTheme.space(1)) {
                Text(scope == .everywhere ? "Activity" : "Session Activity")
                    .themeFont(size: 16, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
                if case .session(_, let title) = scope {
                    Text(title)
                        .themeFont(size: 11.5)
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            if scope == .everywhere {
                HStack(spacing: DefaultTheme.space(2)) {
                    ForEach(Window.allCases) { option in
                        Button { window = option } label: {
                            Text(option.label)
                                .themeFont(size: 11, weight: window == option ? .semibold : .regular)
                                .foregroundStyle(window == option ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                                .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(5))
                                .background(window == option ? DefaultTheme.surface : .clear,
                                            in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DefaultTheme.space(3))
                .background(DefaultTheme.background, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            }
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                GhostButton(systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .help("Re-read the records")
            }
            GhostButton(systemImage: "xmark", action: onClose)
                .help("Close")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DefaultTheme.space(20)).padding(.vertical, DefaultTheme.space(14))
    }

    private func tiles(_ tally: ActivityTally) -> some View {
        HStack(spacing: DefaultTheme.space(10)) {
            tile("MCP calls", tally.total(.mcp))
            tile("Skills", tally.total(.skill))
            tile("Sub-agents", tally.total(.agent))
            tile("Hooks", tally.total(.hook))
            tile("Commands", tally.total(.command))
            tile("Tool calls", tally.total(.tool))
        }
    }

    private func tile(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            Text(title)
                .themeFont(size: 11)
                .foregroundStyle(DefaultTheme.secondaryText)
                .lineLimit(1)
            Text(Self.count(value))
                .themeFont(size: 20, weight: .semibold, design: .rounded)
                .foregroundStyle(value == 0 ? DefaultTheme.mutedText : DefaultTheme.primaryText)
        }
        .padding(DefaultTheme.space(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)).stroke(DefaultTheme.cardBorder))
    }

    /// MCP servers: each opens on its tools.
    private func servers(_ tally: ActivityTally) -> some View {
        let lines = tally.servers
        let top = lines.first?.runs ?? 0
        return card("MCP servers", icon: "puzzlepiece.extension", total: tally.total(.mcp)) {
            if lines.isEmpty {
                emptyLine("None called.")
            }
            ForEach(visible(lines, in: "mcp")) { server in
                let open = expanded.contains("mcp/" + server.name)
                Button { toggle("mcp/" + server.name) } label: {
                    ActivityRow(line: server, top: top, chevron: open ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .help(open ? "Hide this server's tools" : "Show this server's tools")
                if open {
                    ForEach(server.children) { tool in
                        ActivityRow(line: tool, top: server.children.first?.runs ?? 0, isNested: true)
                    }
                }
            }
            more(lines, in: "mcp")
            unusedLine(tally.unusedServers)
        }
    }

    private func ranking(_ title: String, icon: String, kind: ActivityTally.Kind, tally: ActivityTally,
                         empty: String, note: String? = nil, unused: [String] = []) -> some View {
        let lines = tally.lines(kind)
        let top = lines.first?.runs ?? 0
        return card(title, icon: icon, total: tally.total(kind)) {
            if lines.isEmpty {
                emptyLine(empty)
            }
            ForEach(visible(lines, in: kind.rawValue)) { line in
                ActivityRow(line: line, top: top)
            }
            more(lines, in: kind.rawValue)
            unusedLine(unused)
            if let note, !lines.isEmpty {
                Text(note)
                    .themeFont(size: 10.5)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DefaultTheme.space(4))
            }
        }
    }

    private func card<Content: View>(_ title: String, icon: String, total: Int,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(4)) {
            HStack(spacing: DefaultTheme.space(7)) {
                AppIcon(icon, size: 13)
                    .foregroundStyle(DefaultTheme.accentInk)
                Text(title)
                    .themeFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                Text(Self.count(total))
                    .themeFont(size: 11, design: .monospaced)
                    .foregroundStyle(DefaultTheme.mutedText)
            }
            .padding(.bottom, DefaultTheme.space(6))
            content()
        }
        .padding(DefaultTheme.space(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)).stroke(DefaultTheme.cardBorder))
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .themeFont(size: 11.5)
            .foregroundStyle(DefaultTheme.mutedText)
            .padding(.vertical, DefaultTheme.space(4))
    }

    /// "Offered, never called: …": what sits in the session for nothing.
    @ViewBuilder
    private func unusedLine(_ names: [String]) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: DefaultTheme.space(3)) {
                Text("Offered, never called (\(names.count))")
                    .themeFont(size: 10.5, weight: .medium)
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text(names.joined(separator: " · "))
                    .themeFont(size: 10.5, design: .monospaced)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.top, DefaultTheme.space(8))
        }
    }

    // MARK: - Rankings

    private func visible(_ lines: [ActivityTally.Line], in section: String) -> [ActivityTally.Line] {
        expanded.contains("all/" + section) ? lines : Array(lines.prefix(Self.shown))
    }

    @ViewBuilder
    private func more(_ lines: [ActivityTally.Line], in section: String) -> some View {
        if lines.count > Self.shown {
            let all = expanded.contains("all/" + section)
            Button { toggle("all/" + section) } label: {
                Text(all ? "Show the top \(Self.shown)" : "Show all \(lines.count)")
                    .themeFont(size: 11)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.vertical, DefaultTheme.space(3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
        }
    }

    /// "1,204": a count as it reads.
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    // MARK: - Work

    private func refresh() async {
        refreshing = true
        let scope = scope
        let days = window.rawValue
        let read = await Task.detached(priority: .userInitiated) { () -> (ActivityTally?, Int) in
            switch scope {
            case .session(let native, _):
                return (ClaudeActivity.tally(for: native), 1)
            case .everywhere:
                let overview = ClaudeActivity.overview(lastDays: days)
                return (overview.tally, overview.sessions)
            }
        }.value
        guard !Task.isCancelled else { return }
        tally = read.0
        sessions = read.1
        loaded = true
        refreshing = false
    }
}

/// One row of a ranking: the name over a bar as long as its share of the
/// most used, the count at the end, the errors before it when there are some.
private struct ActivityRow: View {
    let line: ActivityTally.Line
    /// The most used of the ranking: the full bar.
    let top: Int
    var chevron: String?
    var isNested = false

    @State private var hovered = false

    private var share: CGFloat {
        top > 0 ? max(0.02, CGFloat(line.runs) / CGFloat(top)) : 0
    }

    var body: some View {
        HStack(spacing: DefaultTheme.space(6)) {
            if let chevron {
                AppIcon(chevron, size: 10)
                    .foregroundStyle(DefaultTheme.mutedText)
            }
            Text(line.name.isEmpty ? "—" : line.name)
                .themeFont(size: isNested ? 11 : 11.5, design: .monospaced)
                .foregroundStyle(isNested ? DefaultTheme.secondaryText : DefaultTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DefaultTheme.space(8))
            if line.failures > 0 {
                Text("\(line.failures) error\(line.failures == 1 ? "" : "s")")
                    .themeFont(size: 10.5, design: .monospaced)
                    .foregroundStyle(DefaultTheme.danger)
            }
            Text(ActivitySheet.count(line.runs))
                .themeFont(size: 11.5, weight: .medium, design: .monospaced)
                .foregroundStyle(DefaultTheme.primaryText)
        }
        .padding(.horizontal, DefaultTheme.space(8))
        .padding(.leading, isNested ? DefaultTheme.space(16) : 0)
        .frame(height: DefaultTheme.size(isNested ? 22 : 26))
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: DefaultTheme.radius(5))
                    .fill(DefaultTheme.accent.opacity(isNested ? 0.08 : (hovered ? 0.2 : 0.14)))
                    .frame(width: proxy.size.width * share)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help("\(line.name) — \(line.runs) run\(line.runs == 1 ? "" : "s")"
              + (line.failures > 0 ? ", \(line.failures) with an error" : ""))
    }
}
